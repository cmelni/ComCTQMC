#include <cstring>
#include <type_traits>
#include <sstream>

#include "Algebra.h"
#include "Variant.h"

#include "../include/Errchk.h"
#include "../include/Allocator.h"

#include "../../../include/BlasLapack.h"
#include "../../../include/mpi/Basic.h"


#ifdef HAVE_CUBLAS

#include <cublas_v2.h>

__device__ double deviceZero = .0;
__device__ double deviceOne  = 1.;
__device__ cublasHandle_t deviceHandle;

__global__ void kerCublasHandle(int const flag) {
    flag ? cublasCreate(&deviceHandle) : cublasDestroy(deviceHandle);
};

#else

#include <cutlass/gemm/gemm.h>
#include <cutlass/gemm/dgemm_traits.h>

#endif


using namespace imp;
using namespace device;


constexpr int WarpSize = 32;  Allocator* alloc = nullptr;


/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////


int imp::pci_id_size() {
    return 16;
}

// @#$!#$@!# cudaGetDevicePciBusId is not working properly on SummitDev ......
void get_pci_id(char* pci_id, int deviceId) {
    std::stringstream stream;
    cudaDeviceProp deviceProperties; cudaErrchk(cudaGetDeviceProperties(&deviceProperties, deviceId));
    stream << std::hex << deviceProperties.pciDomainID << ":" << deviceProperties.pciBusID << ":" << deviceProperties.pciDeviceID;
    std::string str = stream.str(); std::copy(str.begin(), str.end(), pci_id);
}


int imp::get_pci_ids(std::vector<char>& pciIds) {
    int deviceCount; cudaErrchk(cudaGetDeviceCount(&deviceCount));
    
    pciIds.resize(deviceCount*pci_id_size(), '\0');
    for(int id = 0; id < deviceCount; ++id) get_pci_id(&pciIds[id*pci_id_size()], id);
    
    return deviceCount;
}

void imp::init_device(std::vector<char> const& pciId, std::size_t processesPerDevice) {
    int deviceId; cudaErrchk(cudaDeviceGetByPCIBusId(&deviceId, pciId.data()));
    cudaErrchk(cudaSetDevice(deviceId));
    
    cudaDeviceProp deviceProperties; cudaErrchk(cudaGetDeviceProperties(&deviceProperties, deviceId));
    if(deviceProperties.computeMode != cudaComputeModeExclusive && deviceProperties.computeMode != cudaComputeModeExclusiveProcess)
        throw std::runtime_error("Please set GPU compute mode to \"cudaComputeModeExclusive\" or \"cudaComputeModeExclusiveProcess\"");
    if(deviceProperties.warpSize != WarpSize)
        throw std::runtime_error("Please set WarpSize in AlgebraDevice.cu to " + std::to_string(deviceProperties.warpSize));
    
    cudaErrchk(cudaDeviceSetSharedMemConfig(cudaSharedMemBankSizeEightByte));
    
#ifdef HAVE_CUBLAS
    
    kerCublasHandle<<<1, 1>>>(1);
    
#endif
    
    alloc = new Allocator((0.8/processesPerDevice)*deviceProperties.totalGlobalMem);
    
    cudaErrchk(cudaDeviceSynchronize());
}

void imp::release_device() {
    if(!alloc->sanity_check()) throw std::runtime_error("Memory leak !");
    
    delete alloc; 
    alloc = nullptr;
    
#ifdef HAVE_CUBLAS
    
    kerCublasHandle<<<1, 1>>>(0);
    
#endif
    
    cudaErrchk(cudaDeviceSynchronize());
};


/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

//-------------------------------------------------------------------------------------------------------------------------------------------------

imp::Energies<Device>::Energies(jsx::value const& jParams, std::vector<double> const& energies) :
dim0_(energies.size()),
dim_(jParams.is("trunc dim") ? std::min<int>(dim0_, jParams("trunc dim").int64()) : dim0_),
ln_dim_(std::log(dim_)),
data_(alloc->get<double>(dim_)),
min_(std::numeric_limits<double>::max()) {
    for(int i = 0; i < dim_; ++i)
        min_ = std::min(min_, energies[i]);
    
    cudaErrchk(cudaMemcpy(data_.ptr(), energies.data(), dim_*sizeof(double), cudaMemcpyHostToDevice));
}
imp::Energies<Device>::~Energies() {
    alloc->free(data_);
}

//-------------------------------------------------------------------------------------------------------------------------------------------------

imp::Vector<Device>::Vector(double time, Energies<Device> const& energies) :
time_(time),
exponent_(time*energies.min()),
energies_(energies) {
}
imp::Vector<Device>::~Vector() {
}

//-------------------------------------------------------------------------------------------------------------------------------------------------

imp::Matrix<Device, double>::Matrix(int size) : data_(alloc->get<double>(size)) {
}
imp::Matrix<Device, double>::Matrix(Matrix<Device, double>::Identity const& identity) : I_(identity.dim), J_(identity.dim), data_(alloc->get<double>(I_*J_)), exponent_(.0) {
    double* temp = new double[I_*J_]; std::memset(temp, 0, I_*J_*sizeof(double));
    for(int i = 0; i < identity.dim; ++i) temp[i*(identity.dim + 1)] = 1.; //kack memset isch das allgemein für double's ?
    
    cudaErrchk(cudaMemcpy(data_.ptr(), temp, I_*J_*sizeof(double), cudaMemcpyHostToDevice));
    
    delete[] temp;
}
imp::Matrix<Device, double>::Matrix(Matrix<Device, double>::Zero const& zero) : I_(zero.dim), J_(zero.dim), data_(alloc->get<double>(I_*J_)), exponent_(.0) {
    double* temp = new double[I_*J_]; std::memset(temp, 0, I_*J_*sizeof(double));
    
    cudaErrchk(cudaMemcpy(data_.ptr(), temp, I_*J_*sizeof(double), cudaMemcpyHostToDevice));
    
    delete[] temp;
}
imp::Matrix<Device, double>::Matrix(int I, int J, io::rmat const& mat) : I_(I), J_(J), data_(alloc->get<double>(I_*J_)), exponent_(.0) {
    double* temp = new double[I_*J_];
    
    for(int i = 0; i < I; ++i)
        for(int j = 0; j < J; ++j)
            temp[j + J*i] = mat(i, j);
    
    cudaErrchk(cudaMemcpy(data_.ptr(), temp, I_*J_*sizeof(double), cudaMemcpyHostToDevice));
    
    delete[] temp;
}
imp::Matrix<Device, double>::~Matrix() {
    alloc->free(data_);
}

//-------------------------------------------------------------------------------------------------------------------------------------------------

void imp::add(double* dest, double fact, Matrix<Device, double> const& source) {
    int const N = source.I()*source.J(); int const one = 1;
    double* temp = new double[N];                              //Ja scheisse das isch beschisse, passiert aber nit oft.
    
    cudaErrchk(cudaMemcpy(temp, source.data().ptr(), N*sizeof(double), cudaMemcpyDeviceToHost));
    daxpy_(&N, &fact, temp, &one, dest, &one);
    
    delete[] temp;
}


/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

//-------------------------------------------------------------------------------------------------------------------------------------------------

struct CopyEvolveL {
    double time;
    double shift;
    double const* energies;
    double const* source;
    double* dest;
    int I;
    int J;
};

__global__ void kerCopyEvolveL(CopyEvolveL args) {
    int const i = blockIdx.x; int const j = threadIdx.x;

    args.dest[j + blockDim.x*i] = exp(args.time*args.energies[i] - args.shift)*args.source[j + blockDim.x*i];
};

void imp::copyEvolveL(Matrix<Device, double>& dest, Vector<Device> const& prop, Matrix<Device, double> const& source, itf::Batcher<double>& batcher) {
    dest.I() = source.I(); dest.J() = source.J(); dest.exponent() = source.exponent() + prop.exponent(); // eigentli source.exponent() = 0, isch aber sicherer so
    
    auto& args = imp::get<Device>(batcher).get_kernel<CopyEvolveL>();
    
    args.time     = prop.time();
    args.shift    = prop.exponent();
    args.energies = prop.energies().data().ptr();
    args.source   = source.data().ptr();
    args.dest     = dest.data().ptr();
    args.I        = source.I();
    args.J        = source.J();
}

//-------------------------------------------------------------------------------------------------------------------------------------------------

struct Mult {
    double const* A;
    double const* B;
    double* C;
    int M;
    int N;
    int K;
};

#ifndef HAVE_CUBLAS

template <typename KernelClass>
__global__ void cutlass_kernel(typename KernelClass::Params const& params)
{
    extern __shared__ int GemmSharedStorageBase[];
    
    typename KernelClass::SharedStorage *shared_storage =
    reinterpret_cast<typename KernelClass::SharedStorage *>(GemmSharedStorageBase);
    
    KernelClass gemm(params, *shared_storage);
    
    gemm.multiply_add();
}

template<typename BlockShape, typename ThreadShape> 
__device__ void cutlassDgemm(Mult const& args, Byte*& memory)
{
    typedef cutlass::gemm::DgemmTraits<
    cutlass::MatrixLayout::kColumnMajor,   // layout of A matrix
    cutlass::MatrixLayout::kColumnMajor,
    BlockShape,
    cutlass::gemm::LinearScaling<double>,
    ThreadShape
    >
    Traits;
    
    typedef typename Traits::Params Params;
    typedef typename Traits::KernelClass KernelClass;

    memory = reinterpret_cast<Byte*>(reinterpret_cast<unsigned long long>(memory + (alignof(Params) - 1)) & -alignof(Params));

    // Params needs to be trivially destructible ... do not see how to test this in compile time (there is no equivalent to std::is_trivially_destructible in thrust as far as I can see    
    Params& params = *new(memory) Params();  memory += sizeof(Params);

    params.initialize(
                      args.M,
                      args.N,
                      args.K,
                      1.,
                      args.A,
                      args.M,
                      args.B,
                      args.K,
                      .0,
                      args.C,
                      args.M,
                      args.C,
                      args.M
                      );
    
    cutlass_kernel<KernelClass><<< params.grid, params.block, sizeof(typename KernelClass::SharedStorage)>>>(params);
};

#endif

void imp::mult(Matrix<Device, double>& dest, Matrix<Device, double> const& L, Matrix<Device, double> const& R, itf::Batcher<double>& batcher) {
    dest.I() = L.I(); dest.J() = R.J(); dest.exponent() = L.exponent() + R.exponent();
    
    auto& args = imp::get<Device>(batcher).get_kernel<Mult>();
    
    args.A = R.data().ptr();
    args.B = L.data().ptr();
    args.C = dest.data().ptr();
    args.M = R.J();
    args.N = L.I();
    args.K = L.J();
}

//-------------------------------------------------------------------------------------------------------------------------------------------------

struct EvolveL {
    double time;
    double shift;
    double const* energies;
    double* arg;
    int I;
    int J;
};

__global__ void kerEvolveL(EvolveL args) {
    int const i = blockIdx.x; int const j = threadIdx.x;
   
    args.arg[j + blockDim.x*i] *= exp(args.time*args.energies[i] - args.shift);
};

void imp::evolveL(Vector<Device> const& prop, Matrix<Device, double>& arg, itf::Batcher<double>& batcher) {
    arg.exponent() += prop.exponent();
    
    auto& args = imp::get<Device>(batcher).get_kernel<EvolveL>();
    
    args.time     = prop.time();
    args.shift    = prop.exponent();
    args.energies = prop.energies().data().ptr();
    args.arg      = arg.data().ptr();
    args.I        = arg.I();
    args.J        = arg.J();
}

//-------------------------------------------------------------------------------------------------------------------------------------------------

#if __CUDACC_VER_MAJOR__ >= 9

__device__ __forceinline__ void reduceWarp(int const tid, double* data, double* result) {
    double temp;
    temp = data[tid + 16]; __syncwarp();
    data[tid] += temp;     __syncwarp();
    temp = data[tid + 8];  __syncwarp();
    data[tid] += temp;     __syncwarp();
    temp = data[tid + 4];  __syncwarp();
    data[tid] += temp;     __syncwarp();
    temp = data[tid + 2];  __syncwarp();
    data[tid] += temp;     __syncwarp();
    temp = data[tid + 1];  __syncwarp();
    data[tid] += temp;     __syncwarp();
    if(tid == 0) *result = *data;
};

#else

__device__ __forceinline__ void reduceWarp(int const tid, double volatile* data, double* result) {
    data[tid] += data[tid + 16];
    data[tid] += data[tid + 8];
    data[tid] += data[tid + 4];
    data[tid] += data[tid + 2];
    data[tid] += data[tid + 1];
    if(tid == 0) *result = *data;
};

#endif

template<int Size>
__device__ __forceinline__ void reduce(int const tid, double* data, double* result) {
    if(tid < Size/2) data[tid] += data[tid + Size/2];
    __syncthreads();
    reduce<Size/2>(tid, data, result);
};

template<>
__device__ __forceinline__ void reduce<WarpSize>(int const tid, double* data, double* result) {
    if(tid < WarpSize) reduceWarp(tid, data, result);
};

//-------------------------------------------------------------------------------------------------------------------------------------------------

struct Trace {
    double const* arg;
    double* result;
    int dim;
};

template<int BlockDim>
__global__ void kerTrace(Trace args) {
    __shared__ double cache[BlockDim + 16];   // I do not want some threads in the reduceWarp to read stuff outside the cache ... nobody of the nVidia freaks seems to care about this (and probabely they are right) but I do not see why
    cache[threadIdx.x] = .0;
    int i = threadIdx.x;
    
    while(i < args.dim) {
        cache[threadIdx.x] += args.arg[(args.dim + 1)*i];
        
        i += BlockDim;
    }
    __syncthreads();
    
    reduce<BlockDim>(threadIdx.x, cache, args.result);
};

void imp::trace(ut::Zahl<double>* Z, ut::Zahl<double>* accZ, Matrix<Device, double> const& matrix, itf::Batcher<double>& batcher) {
    auto& args = imp::get<Device>(batcher).get_kernel<Trace>(); double exponent = matrix.exponent();
    
    args.arg    = matrix.data().ptr();
    args.result = imp::get<Device>(batcher).get_callback([=](double buffer) { ut::Zahl<double> temp(buffer, exponent); if(Z) *Z = temp; if(accZ) *accZ += temp;});
    args.dim    = matrix.I();
}


//-------------------------------------------------------------------------------------------------------------------------------------------------

struct TraceAtB {
    double const* At;
    double const* B;
    double* result;
    int size;
};

template<int BlockDim>
__global__ void kerTraceAtB(TraceAtB args) {
    __shared__ double cache[BlockDim + 16];
    cache[threadIdx.x] = .0;
    int i = threadIdx.x;
    
    while(i < args.size) {
        cache[threadIdx.x] += args.At[i]*args.B[i];
        
        i += BlockDim;
    }
    __syncthreads();
    
    reduce<BlockDim>(threadIdx.x, cache, args.result);
};

void imp::traceAtB(ut::Zahl<double>* Z, ut::Zahl<double>* accZ, Matrix<Device, double> const& At, Matrix<Device, double> const& B, itf::Batcher<double>& batcher) {
    auto& args = imp::get<Device>(batcher).get_kernel<TraceAtB>(); double exponent = At.exponent() + B.exponent();
    
    args.At     = At.data().ptr();
    args.B      = B.data().ptr();
    args.result = imp::get<Device>(batcher).get_callback([=](double buffer) { ut::Zahl<double> temp(buffer, exponent); if(Z) *Z = temp; if(accZ) *accZ += temp;});
    args.size   = At.I()*At.J();
}


//-------------------------------------------------------------------------------------------------------------------------------------------------

struct Norm {
    double const* arg;
    double* result;
    int size;
};

template<int BlockDim>
__global__ void kerNorm(Norm args) {
    __shared__ double cache[BlockDim + 16];
    cache[threadIdx.x] = .0;
    double value; int i = threadIdx.x;
    
    while(i < args.size) {
        value = args.arg[i];
        cache[threadIdx.x] += value*value;
        
        i += BlockDim;
    }
    __syncthreads();
    
    reduce<BlockDim>(threadIdx.x, cache, args.result);
};

void imp::norm(double* norm, Matrix<Device, double> const& matrix, itf::Batcher<double>& batcher) {
    auto& args = imp::get<Device>(batcher).get_kernel<Norm>(); double exponent = matrix.exponent();
    
    args.arg    = matrix.data().ptr();
    args.result = imp::get<Device>(batcher).get_callback([=](double buffer) { *norm = std::log(buffer)/2. + exponent;});
    args.size   = matrix.I()*matrix.J();
}

//-------------------------------------------------------------------------------------------------------------------------------------------------

void imp::density_matrix(Matrix<Device, double>& dest, Matrix<Device, double> const& B, Vector<Device> const& prop, Matrix<Device, double> const& A, Energies<Device> const& energies, itf::Batcher<double>& batcher) 
{
    throw std::runtime_error("imp::density_matrix: not implemented !");
};

//-------------------------------------------------------------------------------------------------------------------------------------------------

struct Add {
    double const* source;
    double* dest;
    double fact;
    int size;
};

__global__ void kerAdd(Add args)
{
    int const index = blockDim.x*blockIdx.x + threadIdx.x;
    
    if(index < args.size) args.dest[index] += args.fact*args.source[index];
};

void imp::add(Matrix<Device, double>& dest, ut::Zahl<double> const& fact, Matrix<Device, double> const& source, itf::Batcher<double>& batcher)
{
    auto& args = imp::get<Device>(batcher).get_kernel<Add>();
    
    args.source    = source.data().ptr();
    args.dest      = dest.data().ptr();
    args.fact      = (fact*ut::exp(source.exponent())).get();
    args.size      = source.I()*source.J();
}

/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

typedef variant<CopyEvolveL, Mult, EvolveL, Trace, TraceAtB, Norm, Add> KerArgs;

struct alignas(16) imp::Kernel {
    KerArgs args;
    int id;
};

__global__ void kerLauncher(Kernel* kernel, int const N, Byte* memory)
{
    for(int n = 0; n < N; ++n) {
        Kernel&  ker = kernel[n];
        
        if(ker.id == device::index<Mult, KerArgs>::value) {
            
            auto& args = get_device<Mult>(ker.args);
            
#ifdef HAVE_CUBLAS
            
            cublasDgemm(deviceHandle, CUBLAS_OP_N, CUBLAS_OP_N, args.M, args.N, args.K, &deviceOne, args.A, args.M, args.B, args.K, &deviceZero, args.C, args.M);

#else
            
            cutlassDgemm<cutlass::Shape<8, 64, 128>, cutlass::Shape<8, 8, 8>>(args, memory);
            
#endif
            
            
        } else if(ker.id == device::index<Norm, KerArgs>::value) {
            
            auto& args = get_device<Norm>(ker.args);
            kerNorm<1024><<<1, 1024>>>(args);
            
        } else if(ker.id == device::index<EvolveL, KerArgs>::value) {
            
            auto& args = get_device<EvolveL>(ker.args);
            kerEvolveL<<<args.I, args.J>>>(args);
            
        } else if(ker.id == device::index<CopyEvolveL, KerArgs>::value) {
            
            auto& args = get_device<CopyEvolveL>(ker.args);
            kerCopyEvolveL<<<args.I, args.J>>>(args);
            
        } else if(ker.id == device::index<Trace, KerArgs>::value) {
            
            auto& args = get_device<Trace>(ker.args);
            kerTrace<WarpSize><<<1, WarpSize>>>(args);
            
        } else if(ker.id == device::index<TraceAtB, KerArgs>::value) {
            
            auto& args = get_device<TraceAtB>(ker.args);
            kerTraceAtB<1024><<<1, 1024>>>(args);
            
        } else if(ker.id == device::index<Add, KerArgs>::value) {
            
            auto& args = get_device<Add>(ker.args);
            kerAdd<<<(args.size + 256 - 1)/256, 256>>>(args);
            
        }
    }
}

/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////


imp::Batcher<Device, double>::Batcher(std::size_t size) :
size_(size),
numberOfKernels_(0),
phase_(Phase::record),
deviceKernelBuffer_(alloc->get<Kernel>(size_)),
deviceCallBackBuffer_(alloc->get<double>(size_)),
memory_(alloc->get<Byte>(
#ifndef HAVE_CUBLAS 
                         sizeof(typename cutlass::gemm::DgemmTraits<
                                cutlass::MatrixLayout::kColumnMajor,   
                                cutlass::MatrixLayout::kColumnMajor>::Params)*size_
#else
                         8
#endif
                         ))
{
    cudaErrchk(cudaStreamCreate(&stream_));
    
    cudaErrchk(cudaMallocHost(reinterpret_cast<void**>(&hostKernelBuffer_), size_*sizeof(Kernel)));
    cudaErrchk(cudaMallocHost(reinterpret_cast<void**>(&hostCallBackBuffer_), size_*sizeof(double)));
}

double* imp::Batcher<Device, double>::get_callback(std::function<void(double)> callBack) {
    if(phase_ != Phase::record) throw std::runtime_error("imp::Batcher::get_callback");
    
    int index = callBack_.size();  callBack_.push_back(callBack);
    return deviceCallBackBuffer_.ptr() + index;
};

template<typename K>
K& imp::Batcher<Device, double>::get_kernel() {
    if(phase_ != Phase::record) throw std::runtime_error("imp::Batcher::get_kernel");
    
    Kernel& ker = hostKernelBuffer_[numberOfKernels_++];
    ker.id = device::index<K, KerArgs>::value;
    return get_host<K>(ker.args);
};

void imp::Batcher<Device, double>::launch() {
    if(phase_ != Phase::record) throw std::runtime_error("imp::Batcher::launch");
    
    if(numberOfKernels_) {
        cudaErrchk(cudaMemcpyAsync(deviceKernelBuffer_.ptr(), hostKernelBuffer_, numberOfKernels_*sizeof(Kernel), cudaMemcpyHostToDevice, stream_));
        kerLauncher<<<1, 1, 0, stream_>>>(deviceKernelBuffer_.ptr(), numberOfKernels_, memory_.ptr());
        
        numberOfKernels_ = 0; phase_ = Phase::execute;
    }
};

int imp::Batcher<Device, double>::is_ready() {
    if(phase_ == Phase::execute) {
        cudaError_t quest = cudaStreamQuery(stream_);
        
        if(quest == cudaErrorNotReady) return 0;
        
        cudaErrchk(quest);

        if(callBack_.size()) {
            cudaErrchk(cudaMemcpyAsync(hostCallBackBuffer_, deviceCallBackBuffer_.ptr(), callBack_.size()*sizeof(double), cudaMemcpyDeviceToHost, stream_));
            phase_ = Phase::finalize; return 0;
        }
    }
    
    if(phase_ == Phase::finalize) {
        cudaError_t quest = cudaStreamQuery(stream_);
        
        if(quest == cudaErrorNotReady) return 0;
        
        cudaErrchk(quest);
        
        for(std::size_t index = 0; index < callBack_.size(); ++index) callBack_[index](hostCallBackBuffer_[index]);
        callBack_.clear();
    }
    
    phase_ = Phase::record; return 1;
};

imp::Batcher<Device, double>::~Batcher() {
    alloc->free(memory_);
    
    alloc->free(deviceCallBackBuffer_);
    cudaErrchk(cudaFreeHost(hostCallBackBuffer_));
    
    alloc->free(deviceKernelBuffer_);
    cudaErrchk(cudaFreeHost(hostKernelBuffer_));
    
    cudaErrchk(cudaStreamDestroy(stream_));
};







