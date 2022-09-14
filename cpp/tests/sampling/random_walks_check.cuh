/*
 * Copyright (c) 2022, NVIDIA CORPORATION.
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
#include <sampling/random_walks_check.hpp>

#include <utilities/device_comm_wrapper.hpp>

#include <thrust/sort.h>

#include <gtest/gtest.h>

namespace cugraph {
namespace test {

template <typename graph_view_type>
void random_walks_validate(
  raft::handle_t const& handle,
  graph_view_type const& graph_view,
  rmm::device_uvector<typename graph_view_type::vertex_type>&& d_start,
  rmm::device_uvector<typename graph_view_type::vertex_type>&& d_vertices,
  std::optional<rmm::device_uvector<typename graph_view_type::weight_type>>&& d_weights,
  size_t max_length)
{
  // FIXME: The sampling functions should use the standard version, not number_of_vertices
  auto invalid_vertex_id = graph_view.number_of_vertices();

  auto [d_src, d_dst, d_wgt] = graph_view.decompress_to_edgelist(handle, std::nullopt);

  if constexpr (graph_view_type::is_multi_gpu) {
    using vertex_t = typename graph_view_type::vertex_type;
    using weight_t = typename graph_view_type::weight_type;

    d_src = cugraph::test::device_gatherv(
      handle, raft::device_span<vertex_t const>(d_src.data(), d_src.size()));
    d_dst = cugraph::test::device_gatherv(
      handle, raft::device_span<vertex_t const>(d_dst.data(), d_dst.size()));
    if (d_wgt)
      *d_wgt = cugraph::test::device_gatherv(
        handle, raft::device_span<weight_t const>(d_wgt->data(), d_wgt->size()));

    d_vertices = cugraph::test::device_gatherv(
      handle, raft::device_span<vertex_t const>(d_vertices.data(), d_vertices.size()));
    d_start = cugraph::test::device_gatherv(
      handle, raft::device_span<vertex_t const>(d_start.data(), d_start.size()));

    if (d_weights)
      *d_weights = cugraph::test::device_gatherv(
        handle, raft::device_span<weight_t const>(d_weights->data(), d_weights->size()));
  }

  if (d_start.size() > 0) {
    rmm::device_uvector<int> failures(d_start.size() * max_length, handle.get_stream());

    if (d_wgt) {
      thrust::sort(handle.get_thrust_policy(),
                   thrust::make_zip_iterator(d_src.begin(), d_dst.begin(), d_wgt->begin()),
                   thrust::make_zip_iterator(d_src.end(), d_dst.end(), d_wgt->end()));

      thrust::transform(
        handle.get_thrust_policy(),
        thrust::make_counting_iterator(size_t{0}),
        thrust::make_counting_iterator(d_start.size() * max_length),
        failures.begin(),
        [src       = d_src.data(),
         dst       = d_dst.data(),
         wgt       = d_wgt->data(),
         vertices  = d_vertices.data(),
         weights   = d_weights->data(),
         num_edges = d_src.size(),
         invalid_vertex_id,
         max_length] __device__(auto i) {
          auto const s = vertices[(i / max_length) * (max_length + 1) + (i % max_length)];
          auto const d = vertices[(i / max_length) * (max_length + 1) + (i % max_length) + 1];
          auto const w = weights[i];

          // FIXME: if src != invalid_vertex_id and dst == invalid_vertex_id
          //    should add a check to verify that degree(src) == 0
          if (d != invalid_vertex_id) {
            auto iter = thrust::make_zip_iterator(src, dst);
            auto pos  = thrust::find(thrust::seq, iter, iter + num_edges, thrust::make_tuple(s, d));

            if (pos != (iter + num_edges)) {
              auto index = thrust::distance(iter, pos);

              for (; (index < num_edges) && (s == src[index]) && (d == dst[index]); ++index) {
                if (w == wgt[index]) return 0;
              }
              printf("edge (%d,%d) found, got weight %g, did not match expected\n",
                     (int)s,
                     (int)d,
                     (float)w);
            } else {
              printf("edge (%d,%d) NOT FOUND\n", (int)s, (int)d);
            }

            return 1;
          }

          return 0;
        });
    } else {
      thrust::sort(handle.get_thrust_policy(),
                   thrust::make_zip_iterator(d_src.begin(), d_dst.begin()),
                   thrust::make_zip_iterator(d_src.end(), d_dst.end()));

      thrust::transform(
        handle.get_thrust_policy(),
        thrust::make_counting_iterator(size_t{0}),
        thrust::make_counting_iterator(d_start.size() * max_length),
        failures.begin(),
        [src       = d_src.data(),
         dst       = d_dst.data(),
         vertices  = d_vertices.data(),
         num_edges = d_src.size(),
         invalid_vertex_id,
         max_length] __device__(auto i) {
          auto const s = vertices[(i / max_length) * (max_length + 1) + (i % max_length)];
          auto const d = vertices[(i / max_length) * (max_length + 1) + (i % max_length) + 1];

          // FIXME: if src != invalid_vertex_id and dst == invalid_vertex_id
          //    should add a check to verify that degree(src) == 0
          if (d != invalid_vertex_id) {
            auto iter = thrust::make_zip_iterator(src, dst);
            auto pos  = thrust::find(thrust::seq, iter, iter + num_edges, thrust::make_tuple(s, d));

            if (pos == (iter + num_edges)) printf("edge (%d,%d) NOT FOUND\n", (int)s, (int)d);

            return (pos == (iter + num_edges)) ? 1 : 0;
          }

          return 0;
        });
    }

    EXPECT_EQ(0, thrust::reduce(handle.get_thrust_policy(), failures.begin(), failures.end()));
  }
}

}  // namespace test
}  // namespace cugraph
