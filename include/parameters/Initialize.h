#ifndef INCLUDE_PARAMETERS_INITIALIZE_H
#define INCLUDE_PARAMETERS_INITIALIZE_H

#include <complex>

#include "Defaults.h"
#include "../JsonX.h"
#include "../mpi/Utilities.h"
#include "../../ctqmc/include/config/Worms.h"

namespace params {
/*
This is an effort to more sensibly fill out and check the parameter file supplied to ComCTQMC
The goal is to eliminate all checks (jParams.is() ? jParams() : default)
And provide more sensible errors when users mess up the input
It would be nice to do this in a more automatic fashion...
*/


void check_type_against_default(std::string const& entry, jsx::value const& val, jsx::value const& default_val){
    
    if (default_val.is<jsx::boolean_t>() and !val.is<jsx::boolean_t>())
        throw std::runtime_error("Expected boolean for parameter named: " + entry);
    
    //allow promotion of integers to real
    if (default_val.is<jsx::real64_t>() and (!val.is<jsx::real64_t>() and !val.is<jsx::int64_t>()))
        throw std::runtime_error("Expected real number for parameter named: " + entry);
    
    //allow demotion of reals to integers -- can occasionally cause issues although jsonx tries to cast int to real
    if (default_val.is<jsx::int64_t>() and (!val.is<jsx::real64_t>() and !val.is<jsx::int64_t>()))
        throw std::runtime_error("Expected integer for parameter named: " + entry);
    
    if (default_val.is<jsx::string_t>() and !val.is<jsx::string_t>())
        throw std::runtime_error("Expected string for parameter named: " + entry);
    
    if (default_val.is<jsx::array_t>() and !val.is<jsx::array_t>()){
        throw std::runtime_error("Expected array for parameter named: " + entry);
        if (default_val.size() == val.size())
            for (auto const& x : val.array())
                check_type_against_default(entry,x,default_val.array()[0]);
        }
    
    if (default_val.is<jsx::object_t>() and !val.is<jsx::object_t>()){
        throw std::runtime_error("Expected array for parameter named: " + entry);
        if (default_val.size() == val.size()){
            for (auto const& x : default_val.object())
                check_type_against_default(entry + " -> " + x.first, val(x.first), x.second);
        }
    }
}

    void check_required_input(jsx::value const& jParams){
         
        MainRequired required;
        for (auto const& entry : required.get().object()){
            
            if (!jParams.is(entry.first))
                throw std::runtime_error("Parameter file is missing the key " + entry.first);
            
            if (!entry.second.is<jsx::empty_t>())
                for (auto const& sub_entry : entry.second.array())
                    if (!jParams(entry.first).is(sub_entry.string()))
                        throw std::runtime_error("Parameter file is missing the key " + sub_entry.string() + " in block " + entry.first);
            
        }
        
        //check data-types of all required imput except the two-body part which doesn't fit this paradigm
        required.init_types();
        for (auto const& entry : required.get().object()){
            check_type_against_default(entry.first, jParams(entry.first), entry.second);
        }
        
        //check data types of two body input -- basis gets checked in opt::basis?
        jsx::value const& jTwoBody = jParams("hloc")("two body");
        if (jTwoBody.is<jsx::object_t>() and !jTwoBody.is("imag")){
            
            if (!jParams.is("basis"))
                throw std::runtime_error("If the two body tensor is not explicity defined, you must supply the one-particle basis");
            
        }
             
         
     }




    struct worm_defaults_functor {
        template<typename W>
        void operator()(ut::wrap<W> w, jsx::value & jParams, AllDefaults const& defaults) const {
            
            if( W::name() != cfg::partition::Worm::name() && jParams.is(W::name()) ) {
                
                if (cfg::worm_size<W>::value == 2){
                    for (auto const& entry : defaults.oneTimeWormDefaults.get().object()){
                        if (!jParams(W::name()).is(entry.first))
                            jParams[W::name()][entry.first] = entry.second;
                        else check_type_against_default(W::name() + " -> " + entry.first, jParams[W::name()][entry.first], entry.second);
                    }
                } else {
                    for (auto const& entry : defaults.multiTimeWormDefaults.get().object()){
                        if (!jParams(W::name()).is(entry.first))
                            jParams[W::name()][entry.first] = entry.second;
                        else check_type_against_default(W::name() + " -> " + entry.first, jParams[W::name()][entry.first], entry.second);
                    }
                }
            }
        }
    };


    void add_default_worms( jsx::value & jParams, AllDefaults const& defaults) {
        
        for (auto const& worm : defaults.listOfDefaultWorms){
            jParams[worm] = jsx::object_t();
            jParams[worm]["meas"] = jsx::array_t({"imprsum"});
        }
        
    }

    struct worm_cutoffs_functor {
        template<typename W>
           void operator()(ut::wrap<W> w, jsx::value & jParams, int const fermion_cutoff, int const boson_cutoff) const {
                
               if( W::name() != cfg::partition::Worm::name() && jParams.is(W::name()) ) {
                   
                   auto & jWorm = jParams[W::name()];
                   
                   if (jWorm.is("fermion cutoff") and jWorm("basis").string() == "matsubara" ) jWorm["fermion cutoff"] = fermion_cutoff;
                   if (jWorm.is("matsubara cutoff")) jWorm["matsubara cutoff"] = fermion_cutoff;
                   
                   if (jWorm.is("cutoff")) jWorm["cutoff"] = boson_cutoff;
                   if (jWorm.is("boson cutoff")) jWorm["boson cutoff"] = boson_cutoff;
                       
                
               }
               
           }
    };
 
    void set_default_values(jsx::value & jParams){
        
        AllDefaults defaults(jParams);
        
        for (auto const& entry : defaults.mainDefaults.get().object()){
            if (!jParams.is(entry.first)) jParams[entry.first] = entry.second;
            else check_type_against_default("Main block -> " + entry.first, jParams[entry.first], entry.second);
        }
        
        for (auto const& entry : defaults.partitionSpaceDefaults.get().object()){
            if (!jParams(cfg::partition::Worm::name()).is(entry.first)) jParams[cfg::partition::Worm::name()][entry.first] = entry.second;
            else check_type_against_default(cfg::partition::Worm::name() + " -> " + entry.first, jParams[cfg::partition::Worm::name()][entry.first], entry.second);
        }
        
        cfg::for_each_type<cfg::Worm>::apply(worm_defaults_functor(), jParams, defaults);
    }

    void initialize(jsx::value & jParams){
        
        check_required_input(jParams);
        set_default_values(jParams);
        mpi::write(jParams, "defaults.json");
        
    }

}

#endif
