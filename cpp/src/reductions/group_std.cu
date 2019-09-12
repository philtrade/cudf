/*
 * Copyright (c) 2019, NVIDIA CORPORATION.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#include "group_reductions.hpp"

#include <bitmask/legacy/bit_mask.cuh>
#include <cudf/utilities/legacy/type_dispatcher.hpp>

#include <thrust/reduce.h>
#include <thrust/iterator/discard_iterator.h>

namespace {

template <typename T>
void print(rmm::device_vector<T> const& d_vec, std::string label = "") {
  thrust::host_vector<T> h_vec = d_vec;
  printf("%s \t", label.c_str());
  for (auto &&i : h_vec)  std::cout << i << " ";
  printf("\n");
}

template <typename T>
void print(gdf_column const& col, std::string label = "") {
  auto col_data = reinterpret_cast<T*>(col.data);
  auto d_vec = rmm::device_vector<T>(col_data, col_data+col.size);
  print(d_vec, label);
}

struct var_functor {
  template <typename T>
  std::enable_if_t<std::is_arithmetic<T>::value, void >
  operator()(gdf_column const& values,
             rmm::device_vector<gdf_size_type> const& group_labels,
             rmm::device_vector<gdf_size_type> const& group_sizes,
             gdf_column * result,
             gdf_size_type ddof,
             cudaStream_t stream)
  {
    print(group_labels, "labels");
    print(group_sizes, "sizes");
    print<T>(values, "values");

    auto values_data = static_cast<const T*>(values.data);
    auto result_data = static_cast<double *>(result->data);
    auto values_valid = reinterpret_cast<const bit_mask::bit_mask_t*>(values.valid);
    auto result_valid = reinterpret_cast<bit_mask::bit_mask_t*>(result->valid);
    const gdf_size_type* d_group_labels = group_labels.data().get();
    const gdf_size_type* d_group_sizes = group_sizes.data().get();
    
    // Calculate sum
    // TODO: replace with mean function call when that gets an internal API
    rmm::device_vector<T> sums(values.size);

    thrust::reduce_by_key(rmm::exec_policy(stream)->on(stream),
                          group_labels.begin(), group_labels.end(),
                          thrust::make_transform_iterator(
                            thrust::make_counting_iterator(0),
                            [=] __device__ (gdf_size_type i) -> T {
                              return (values_valid and not bit_mask::is_valid(values_valid, i))
                                     ? 0 : values_data[i];
                            }),
                          thrust::make_discard_iterator(),
                          sums.begin());
    print(sums, "sums");

    // TODO: use target_type for sums and result_data
    T* d_sums = sums.data().get();

    auto values_it = thrust::make_transform_iterator(
      thrust::make_counting_iterator(0),
      [=] __device__ (gdf_size_type i) {
        if (values_valid and not bit_mask::is_valid(values_valid, i))
          return 0.0;
        
        double x = values_data[i];
        gdf_size_type group_idx = d_group_labels[i];
        gdf_size_type group_size = d_group_sizes[group_idx];
        
        // prevent divide by zero error
        if (group_size == 0 or group_size - ddof <= 0)
          return 0.0;

        double mean = static_cast<double>(d_sums[group_idx])/group_size;
        return (x - mean) * (x - mean) / (group_size - ddof);
      }
    );

    thrust::reduce_by_key(rmm::exec_policy(stream)->on(stream),
                          group_labels.begin(), group_labels.end(), values_it, 
                          thrust::make_discard_iterator(),
                          result_data);

    // set nulls
    if (result_valid) {
      thrust::for_each_n(thrust::make_counting_iterator(0), group_sizes.size(),
        [=] __device__ (gdf_size_type i){
          gdf_size_type group_size = d_group_sizes[i];
          if (group_size == 0 or group_size - ddof <= 0)
            bit_mask::clear_bit_safe(result_valid, i);
          else
            bit_mask::set_bit_safe(result_valid, i);
        });
    }
    
  }

  template <typename T, typename... Args>
  std::enable_if_t<!std::is_arithmetic<T>::value, void >
  operator()(Args&&... args) {
    CUDF_FAIL("Only numeric types are supported in variance");
  }
};

} // namespace anonymous


namespace cudf {
namespace detail {

void group_var(gdf_column const& values,
               rmm::device_vector<gdf_size_type> const& group_labels,
               rmm::device_vector<gdf_size_type> const& group_sizes,
               gdf_column * result,
               gdf_size_type ddof,
               cudaStream_t stream)
{
  type_dispatcher(values.dtype, var_functor{},
    values, group_labels, group_sizes, result, ddof, stream);
}

void group_std(gdf_column const& values,
               rmm::device_vector<gdf_size_type> const& group_labels,
               rmm::device_vector<gdf_size_type> const& group_sizes,
               gdf_column * result,
               gdf_size_type ddof,
               cudaStream_t stream)
{
  type_dispatcher(values.dtype, var_functor{},
    values, group_labels, group_sizes, result, ddof, stream);
}

} // namespace detail
} // namespace cudf
