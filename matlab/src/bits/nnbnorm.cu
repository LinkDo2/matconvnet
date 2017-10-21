// @file nnbnorm.cu
// @brief Batch normalization block
// @author Sebastien Ehrhardt
// @author Andrea Vedaldi

/*
 Copyright (C) 2015-17 Sebastien Ehrhardt and Andrea Vedaldi.
 All rights reserved.

 This file is part of the VLFeat library and is made available under
 the terms of the BSD license (see the COPYING file).
 */

#include "nnbnorm.hpp"
#include "impl/dispatcher.hpp"
#include <cassert>
#include <cstring>
#include <cmath>
#include <cstdlib>
#include <limits>
#include <algorithm>
#include <iostream>

using namespace vl ;
using namespace vl::nn ;
using namespace vl::impl ;

template<DeviceType deviceType, DataType dataType> struct BatchNormForward ;
template<DeviceType deviceType, DataType dataType> struct BatchNormForwardWithMoment ;
template<DeviceType deviceType, DataType dataType> struct BatchNormBackward ;
template<DeviceType deviceType, DataType dataType> struct BatchNormBackwardWithMoment ;

template<DataType dataType> struct BatchNormForwardCudnn ;
template<DataType dataType> struct BatchNormForwardWithMomentCudnn ;
template<DataType dataType> struct BatchNormBackwardCudnn ;
template<DataType dataType> struct BatchNormBackwardWithMomentCudnn ;

// -------------------------------------------------------------------
//                                                             Helpers
// -------------------------------------------------------------------

// Compute moments (means and sigmas) from the batch data
// WH is the product of the data width and height
// moments is a 2 x depth array with means and sigmas

template<typename T> inline void
compute_moment(T * moments,
               T const * data,
               Int WH,
               Int depth,
               Int num,
               T epsilon)
{
  memset(moments, 0, sizeof(T) * 2 * as_unsigned(depth)) ;
  Int mass = WH * num ;
  for(Int channel = 0; channel < depth; ++channel) {
    for(Int element = 0; element < num; ++element) {
      for(Int wh = 0; wh < WH; ++wh){
        T x = data[wh + channel*WH + element*(depth*WH)] ;
        moments[channel] += x ; // mean
        moments[channel + depth] += x * x; // sigma
      }
    }
  }
  for(Int i = 0; i < depth; ++i) {
    T mean = moments[i] / mass ;
    T sigma2 = std::max((T).0, moments[i + depth]/mass - mean*mean) ;
    moments[i] = mean ;
    moments[i + depth] = sqrt(sigma2 + epsilon);
  }
}

// This version assumes that the moment tensor is precomputed.
template<typename T> inline void
compute_ders(T * derMultipliers,
             T * derBiases,
             T const * moments,
             T const * data,
             T const * derOutput,
             Int WH, Int depth, Int num,
             T epsilon)
{
  memset(derMultipliers, 0, sizeof(T) * (size_t)depth) ;
  memset(derBiases, 0, sizeof(T) * (size_t)depth) ;
  for(Int channel = 0; channel < depth; ++channel){
    for(Int element = 0; element < num; ++element ){
      for(Int wh = 0; wh < WH; ++wh){
        auto offset = wh + channel * WH + element * (WH*depth) ;
        derMultipliers[channel] += derOutput[offset] * data[offset];
        derBiases[channel] += derOutput[offset];
      }
    }
  }
  for(Int i = 0; i < depth; ++i) {
    T mean = moments[i] ;
    T sigma = moments[i + depth] ;
    derMultipliers[i] = (derMultipliers[i] - mean*derBiases[i]) / sigma;
  }
}

template<typename T> inline void
compute_ders_and_moments(T * derMultipliers,
                         T * derBiases,
                         T * moments,
                         T const * data,
                         T const * derOutput,
                         Int WH,
                         Int depth,
                         Int num,
                         T epsilon)
{
  memset(derMultipliers, 0, sizeof(T) * (size_t)depth) ;
  memset(derBiases, 0, sizeof(T) * (size_t)depth) ;
  memset(moments, 0, sizeof(T) * 2 * (size_t)depth) ;
  for(Int channel = 0; channel < depth; ++channel) {
    for(Int element = 0; element < num; ++element) {
      for(Int wh = 0; wh < WH; ++wh){
        auto offset = wh + channel * WH + element * (WH*depth) ;
        moments[channel] += data[offset] ;
        moments[channel + depth] += data[offset] * data[offset];
        derMultipliers[channel] += derOutput[offset] * data[offset];
        derBiases[channel] += derOutput[offset];
      }
    }
  }

  T mass = (T)(WH*num) ;
  for(Int i = 0; i < depth; ++i) {
    T mean = moments[i] / mass ;
    T sigma2 = std::max((T).0, moments[i + depth]/mass - mean*mean) ;
    T sigma = sqrt(sigma2 + epsilon);
    moments[i] = mean ;
    moments[i + depth] = sigma ;
    derMultipliers[i] = (derMultipliers[i] - mean*derBiases[i]) / sigma;
  }
}

template<typename T> inline void
batch_normalize_backward(T * derData,
                         T const * moments,
                         T const * data,
                         T const * multipliers,
                         T const * derMultipliers,
                         T const * derBiases,
                         T const * derOutput,
                         Int WH,
                         Int depth,
                         Int num)
{
  T mass = (T)(WH*num) ;
  for (Int channel = 0; channel < depth; ++channel) {
    T mean = moments[channel] ;
    T sigma = moments[channel + depth] ;

    T muz = derBiases[channel]/mass ;
    T G1 = multipliers[channel]/sigma ;
    T G2 = G1 * derMultipliers[channel]/(mass*sigma) ;

    for (Int element = 0; element < num; ++element){
      for (Int wh = 0; wh < WH; ++wh){
        auto offset = wh + channel * WH + element * (WH*depth) ;
        derData[offset] = G1 * (derOutput[offset] - muz) - G2 * (data[offset]-mean) ;
      }
    }
  }
}

// -------------------------------------------------------------------
//                                                             Forward
// -------------------------------------------------------------------

template<DataType dataType>
struct BatchNormForwardWithMoment<VLDT_CPU, dataType>
{
  vl::ErrorCode operator()(BatchNorm &op,
                           Tensor &output,
                           Tensor const &moment,
                           Tensor const &input,
                           Tensor const &multiplier,
                           Tensor const &bias)
  {
    typedef typename vl::DataTypeTraits<dataType>::type type ;
    auto height = input.getHeight() ;
    auto width = input.getWidth() ;
    auto depth = input.getNumChannels() ;
    auto cardinality = input.getCardinality() ;
    auto outputData = (type*)output.getMemory() ;
    auto momentData = (type const*)moment.getMemory() ;
    auto inputData = (type const*)input.getMemory() ;
    auto multiplierData = (type const*)multiplier.getMemory() ;
    auto biasData = (type const*)bias.getMemory() ;
    auto WH = height * width ;

    for(decltype(depth) channel = 0; channel < depth; ++channel) {
      type mean = momentData[channel] ;
      type sigma = momentData[channel + depth] ;
      type bias = biasData[channel];
      type coefficient = multiplierData[channel] / sigma ;

      for(decltype(cardinality) element = 0; element < cardinality; ++element) {
        for(decltype(WH) wh = 0; wh < WH; ++wh){
          auto offset = wh + channel * WH + element * depth * WH ;
          outputData[offset] = coefficient * (inputData[offset] - mean) + bias ;
        }
      }
    }
    return VLE_Success ;
  }
} ;

template<DataType dataType>
struct BatchNormForward<VLDT_CPU, dataType>
{
  vl::ErrorCode operator()(BatchNorm &op,
                           Tensor &output,
                           Tensor &moment,
                           Tensor const &input,
                           Tensor const &multiplier,
                           Tensor const &bias)
  {
    vl::ErrorCode error = VLE_Success ;
    typedef typename vl::DataTypeTraits<dataType>::type type ;
    auto height = input.getHeight() ;
    auto width = input.getWidth() ;
    auto depth = input.getNumChannels() ;
    auto cardinality = input.getCardinality() ;
    auto inputData = (type const*)input.getMemory() ;

    // Compute the moments.
    Tensor ownMoment(moment) ;
    if (ownMoment.getMemory() == NULL) {
      auto * buffer = (type*)op.getContext().getWorkspace
      (vl::VLDT_CPU, sizeof(type)*2*size_t(depth)) ;
      if (!buffer) {
        error = VLE_OutOfMemory ;
        goto done ;
      }
      ownMoment.setMemory(buffer) ;
    }

    {
      auto momentData = (type*)ownMoment.getMemory() ;
      compute_moment<type>(momentData, inputData,
                           width*height, depth, cardinality,
                           (type)op.getEpsilon()) ;
    }

    // Compute output.
    error = BatchNormForwardWithMoment<vl::VLDT_CPU,dataType>()
    (op,output,ownMoment,input,multiplier,bias) ;

    // Finish.
  done:
    return error ;
  }
} ;


// -------------------------------------------------------------------
//                                                            Backward
// -------------------------------------------------------------------

template<DataType dataType>
struct BatchNormBackwardWithMoment<VLDT_CPU, dataType>
{
  vl::ErrorCode operator()(BatchNorm &op,
                           Tensor &derInput,
                           Tensor &derMultiplier,
                           Tensor &derBias,
                           Tensor const &moment,
                           Tensor const &input,
                           Tensor const &multiplier,
                           Tensor const &bias,
                           Tensor const &derOutput)
  {
    typedef typename vl::DataTypeTraits<dataType>::type type ;
    Int height = input.getHeight() ;
    Int width = input.getWidth() ;
    Int depth = input.getNumChannels() ;
    Int cardinality = input.getCardinality() ;
    Int WH = height * width ;

    auto derInputData = (type*)derInput.getMemory() ;
    auto derMultiplierData = (type*)derMultiplier.getMemory() ;
    auto derBiasData = (type*)derBias.getMemory() ;
    auto momentData = (type const*)moment.getMemory() ;
    auto inputData = (type const*)input.getMemory() ;
    auto multiplierData = (type const*)multiplier.getMemory() ;
    auto derOutputData = (type const*)derOutput.getMemory() ;

    // Compute derMultipliers, derBiases, muz, and moments.
    compute_ders<type>(derMultiplierData, derBiasData,
                       momentData, inputData, derOutputData,
                       WH, depth, cardinality,
                       (type)op.getEpsilon());

    // Compute derData.
    batch_normalize_backward<type>(derInputData,
                                   momentData, inputData,
                                   multiplierData,
                                   derMultiplierData, derBiasData, derOutputData,
                                   WH, depth, cardinality);
    return VLE_Success ;
  }
} ;

template<DataType dataType>
struct BatchNormBackward<VLDT_CPU, dataType>
{
  vl::ErrorCode operator()(BatchNorm &op,
                           Tensor &derInput,
                           Tensor &derMultiplier,
                           Tensor &derBias,
                           Tensor &moment,
                           Tensor const &input,
                           Tensor const &multiplier,
                           Tensor const &bias,
                           Tensor const &derOutput)
  {
    vl::ErrorCode error = VLE_Success ;
    typedef typename vl::DataTypeTraits<dataType>::type type ;
    Int height = input.getHeight() ;
    Int width = input.getWidth() ;
    Int depth = input.getNumChannels() ;
    Int cardinality = input.getCardinality() ;
    Int WH = height * width ;

    auto derInputData = (type*)derInput.getMemory() ;
    auto derMultiplierData = (type*)derMultiplier.getMemory() ;
    auto derBiasData = (type*)derBias.getMemory() ;
    auto inputData = (type const*)input.getMemory() ;
    auto multiplierData = (type const*)multiplier.getMemory() ;
    auto derOutputData = (type const*)derOutput.getMemory() ;

    // Get workspace if needed.
    Tensor ownMoment(moment) ;
    if (ownMoment.getMemory() == NULL) {
      auto buffer = (type*)op.getContext().getWorkspace
      (vl::VLDT_CPU, sizeof(type)*2*size_t(depth)) ;
      if (!buffer) {
        error = VLE_OutOfMemory ;
        goto done ;
      }
      ownMoment.setMemory(buffer) ;
    }

    {
      auto momentData = (type*)ownMoment.getMemory() ;

      // Compute derMultipliers, derBiases, and moments.
      compute_ders_and_moments<type>(derMultiplierData, derBiasData, momentData,
                                     inputData, derOutputData,
                                     WH, depth, cardinality,
                                     (type)op.getEpsilon());

      // Compute derData.
      batch_normalize_backward<type>(derInputData,
                                     momentData, inputData,
                                     multiplierData,
                                     derMultiplierData, derBiasData, derOutputData,
                                     WH, depth, cardinality);
    }
  done:;
    return error ;
  }
} ;

// -------------------------------------------------------------------
//                                                              Driver
// -------------------------------------------------------------------

#if ENABLE_GPU
#include "nnbnorm_gpu.cu"
#endif

#if ENABLE_CUDNN
#include "nnbnorm_cudnn.cu"
#endif

BatchNorm::BatchNorm(Context &context,
                     double epsilon)
:
Operation(context),
epsilon(epsilon)
{ }

vl::ErrorCode
BatchNorm::forward(Tensor &output,
                   Tensor &moment,
                   Tensor const &input,
                   Tensor const &multiplier,
                   Tensor const &bias)
{
  return dispatch_cudnn<
  BatchNormForward,
  BatchNormForwardCudnn>()
  (*this,output,moment,input,multiplier,bias) ;
}

vl::ErrorCode
BatchNorm::forwardWithMoment(Tensor &output,
                             Tensor const &moment,
                             Tensor const &input,
                             Tensor const &multiplier,
                             Tensor const &bias)
{
  return dispatch_cudnn<
  BatchNormForwardWithMoment,
  BatchNormForwardWithMomentCudnn>()
  (*this,output,moment,input,multiplier,bias) ;
}

vl::ErrorCode
BatchNorm::backward(Tensor &derInput,
                    Tensor &derMultiplier,
                    Tensor &derBias,
                    Tensor &moment,
                    Tensor const &input,
                    Tensor const &multiplier,
                    Tensor const &bias,
                    Tensor const &derOutput)
{
  return dispatch_cudnn<
  BatchNormBackward,
  BatchNormBackwardCudnn>()
  (*this,derInput,derMultiplier,derBias,moment,input,multiplier,bias,derOutput) ;
}

vl::ErrorCode
BatchNorm::backwardWithMoment(Tensor &derInput,
                              Tensor &derMultiplier,
                              Tensor &derBias,
                              Tensor const &moment,
                              Tensor const &input,
                              Tensor const &multiplier,
                              Tensor const &bias,
                              Tensor const &derOutput)
{
  return dispatch_cudnn<
  BatchNormBackwardWithMoment,
  BatchNormBackwardWithMomentCudnn>()
  (*this,derInput,derMultiplier,derBias,moment,input,multiplier,bias,derOutput) ;
}
