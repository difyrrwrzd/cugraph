/*
 * Copyright (c) 2020, NVIDIA CORPORATION.
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
 * See the License for the specific language governin_from_mtxg permissions and
 * limitations under the License.
 */

#include <utilities/base_fixture.hpp>
#include <utilities/test_utilities.hpp>

#include <algorithms.hpp>
#include <experimental/graph.hpp>
#include <experimental/graph_functions.hpp>
#include <experimental/graph_view.hpp>

#include <raft/cudart_utils.h>
#include <raft/handle.hpp>
#include <rmm/device_uvector.hpp>
#include <rmm/mr/device/cuda_memory_resource.hpp>

#include <gtest/gtest.h>

#include <algorithm>
#include <map>
#include <random>
#include <tuple>
#include <type_traits>
#include <vector>

template <typename vertex_t>
std::enable_if_t<std::is_signed<vertex_t>::value, bool> is_valid_vertex(vertex_t num_vertices,
                                                                        vertex_t v)
{
  return (v >= 0) && (v < num_vertices);
}

template <typename vertex_t>
std::enable_if_t<std::is_unsigned<vertex_t>::value, bool> is_valid_vertex(vertex_t num_vertices,
                                                                          vertex_t v)
{
  return v < num_vertices;
}

template <typename vertex_t, typename edge_t, typename weight_t>
void check_coarsened_graph_results(edge_t* org_offsets,
                                   vertex_t* org_indices,
                                   weight_t* org_weights,
                                   vertex_t* org_labels,
                                   edge_t* coarse_offsets,
                                   vertex_t* coarse_indices,
                                   weight_t* coarse_weights,
                                   vertex_t* coarse_vertex_labels,
                                   vertex_t num_org_vertices,
                                   vertex_t num_coarse_vertices)
{
  ASSERT_TRUE(((org_weights == nullptr) && (coarse_weights == nullptr)) ||
              ((org_weights != nullptr) && (coarse_weights != nullptr)));
  ASSERT_TRUE(std::is_sorted(org_offsets, org_offsets + num_org_vertices));
  ASSERT_TRUE(std::count_if(org_indices,
                            org_indices + org_offsets[num_org_vertices],
                            [num_org_vertices](auto nbr) {
                              return !is_valid_vertex(num_org_vertices, nbr);
                            }) == 0);
  ASSERT_TRUE(std::is_sorted(coarse_offsets, coarse_offsets + num_coarse_vertices));
  ASSERT_TRUE(std::count_if(coarse_indices,
                            coarse_indices + coarse_offsets[num_coarse_vertices],
                            [num_coarse_vertices](auto nbr) {
                              return !is_valid_vertex(num_coarse_vertices, nbr);
                            }) == 0);
  ASSERT_TRUE(num_coarse_vertices <= num_org_vertices);

  std::vector<vertex_t> unique_labels(num_org_vertices);
  std::copy(org_labels, org_labels + num_org_vertices, unique_labels.begin());
  std::sort(unique_labels.begin(), unique_labels.end());
  auto last = std::unique(unique_labels.begin(), unique_labels.end());
  unique_labels.resize(std::distance(unique_labels.begin(), last));
  ASSERT_TRUE(unique_labels.size() == static_cast<size_t>(num_coarse_vertices));

  {
    std::vector<vertex_t> tmp_coarse_vertex_labels(coarse_vertex_labels,
                                                   coarse_vertex_labels + num_coarse_vertices);
    std::sort(tmp_coarse_vertex_labels.begin(), tmp_coarse_vertex_labels.end());
    auto last = std::unique(tmp_coarse_vertex_labels.begin(), tmp_coarse_vertex_labels.end());
    ASSERT_TRUE(last == tmp_coarse_vertex_labels.end());
    ASSERT_TRUE(
      std::equal(unique_labels.begin(), unique_labels.end(), tmp_coarse_vertex_labels.begin()));
  }

  std::vector<std::tuple<vertex_t, vertex_t>> label_org_vertex_pairs(num_org_vertices);
  for (vertex_t i = 0; i < num_org_vertices; ++i) {
    label_org_vertex_pairs[i] = std::make_tuple(org_labels[i], i);
  }
  std::sort(label_org_vertex_pairs.begin(), label_org_vertex_pairs.end());

  std::vector<vertex_t> unique_label_counts(unique_labels.size());
  std::vector<vertex_t> unique_label_offsets(unique_label_counts.size() + 1, 0);
  std::transform(
    unique_labels.begin(),
    unique_labels.end(),
    unique_label_counts.begin(),
    [&label_org_vertex_pairs](auto label) {
      auto lb = std::lower_bound(
        label_org_vertex_pairs.begin(),
        label_org_vertex_pairs.end(),
        std::make_tuple(label, cugraph::experimental::invalid_vertex_id<vertex_t>::value),
        [](auto lhs, auto rhs) { return std::get<0>(lhs) < std::get<0>(rhs); });
      auto ub = std::upper_bound(
        label_org_vertex_pairs.begin(),
        label_org_vertex_pairs.end(),
        std::make_tuple(label, cugraph::experimental::invalid_vertex_id<vertex_t>::value),
        [](auto lhs, auto rhs) { return std::get<0>(lhs) < std::get<0>(rhs); });
      return static_cast<vertex_t>(std::distance(lb, ub));
    });
  std::partial_sum(
    unique_label_counts.begin(), unique_label_counts.end(), unique_label_offsets.begin() + 1);

  std::map<vertex_t, vertex_t> label_to_coarse_vertex_map{};
  for (vertex_t i = 0; i < num_coarse_vertices; ++i) {
    label_to_coarse_vertex_map[coarse_vertex_labels[i]] = i;
  }

  for (size_t i = 0; i < unique_labels.size(); ++i) {
    auto count  = unique_label_counts[i];
    auto offset = unique_label_offsets[i];
    if (org_weights == nullptr) {
      std::vector<vertex_t> coarse_nbrs0{};
      for (vertex_t j = offset; j < offset + count; ++j) {
        auto org_vertex = std::get<1>(label_org_vertex_pairs[j]);
        for (auto k = org_offsets[org_vertex]; k < org_offsets[org_vertex + 1]; ++k) {
          auto org_nbr    = org_indices[k];
          auto coarse_nbr = label_to_coarse_vertex_map[org_labels[org_nbr]];
          coarse_nbrs0.push_back(coarse_nbr);
        }
      }
      std::sort(coarse_nbrs0.begin(), coarse_nbrs0.end());
      auto last = std::unique(coarse_nbrs0.begin(), coarse_nbrs0.end());
      coarse_nbrs0.resize(std::distance(coarse_nbrs0.begin(), last));

      auto coarse_vertex = label_to_coarse_vertex_map[unique_labels[i]];
      auto coarse_offset = coarse_offsets[coarse_vertex];
      auto coarse_count  = coarse_offsets[coarse_vertex + 1] - coarse_offset;
      std::vector<vertex_t> coarse_nbrs1(coarse_indices + coarse_offset,
                                         coarse_indices + coarse_offset + coarse_count);
      std::sort(coarse_nbrs1.begin(), coarse_nbrs1.end());

      ASSERT_TRUE(std::equal(coarse_nbrs0.begin(), coarse_nbrs0.end(), coarse_nbrs1.begin()));
    } else {
      std::vector<std::tuple<vertex_t, weight_t>> coarse_nbr_weight_pairs0{};
      for (vertex_t j = offset; j < offset + count; ++j) {
        auto org_vertex = std::get<1>(label_org_vertex_pairs[j]);
        for (auto k = org_offsets[org_vertex]; k < org_offsets[org_vertex + 1]; ++k) {
          auto org_nbr    = org_indices[k];
          auto org_weight = org_weights[k];
          auto coarse_nbr = label_to_coarse_vertex_map[org_labels[org_nbr]];
          coarse_nbr_weight_pairs0.push_back(std::make_tuple(coarse_nbr, org_weight));
        }
      }
      std::sort(coarse_nbr_weight_pairs0.begin(), coarse_nbr_weight_pairs0.end());
      // reduce by key
      {
        size_t run_start_idx = 0;
        for (size_t i = 1; i < coarse_nbr_weight_pairs0.size(); ++i) {
          auto& start = coarse_nbr_weight_pairs0[run_start_idx];
          auto& cur   = coarse_nbr_weight_pairs0[i];
          if (std::get<0>(start) == std::get<1>(cur)) {
            std::get<1>(start) += std::get<1>(cur);
            std::get<0>(cur) = cugraph::experimental::invalid_vertex_id<vertex_t>::value;
          } else {
            run_start_idx = i;
          }
        }
        coarse_nbr_weight_pairs0.erase(
          std::remove_if(coarse_nbr_weight_pairs0.begin(),
                         coarse_nbr_weight_pairs0.end(),
                         [](auto t) {
                           return std::get<0>(t) ==
                                  cugraph::experimental::invalid_vertex_id<vertex_t>::value;
                         }),
          coarse_nbr_weight_pairs0.end());
      }

      auto coarse_vertex = label_to_coarse_vertex_map[unique_labels[i]];
      auto coarse_offset = coarse_offsets[coarse_vertex];
      auto coarse_count  = coarse_offsets[coarse_vertex + 1] - coarse_offset;
      std::vector<std::tuple<vertex_t, weight_t>> coarse_nbr_weight_pairs1(coarse_count);
      for (auto j = coarse_offset; j < coarse_offset + coarse_count; ++j) {
        coarse_nbr_weight_pairs1[i - coarse_offset] =
          std::make_tuple(coarse_indices[j], coarse_weights[j]);
      }
      std::sort(coarse_nbr_weight_pairs1.begin(), coarse_nbr_weight_pairs1.end());

      auto threshold_ratio = weight_t{1e-4};
      auto threshold_magnitude =
        ((std::accumulate(
            coarse_weights, coarse_weights + coarse_offsets[num_coarse_vertices], weight_t{0.0}) /
          static_cast<weight_t>(coarse_offsets[num_coarse_vertices])) *
         threshold_ratio) *
        threshold_ratio;
      ASSERT_TRUE(std::equal(
        coarse_nbr_weight_pairs0.begin(),
        coarse_nbr_weight_pairs0.end(),
        coarse_nbr_weight_pairs1.begin(),
        [threshold_ratio, threshold_magnitude](auto lhs, auto rhs) {
          return std::get<0>(lhs) == std::get<0>(rhs)
                   ? (std::abs(std::get<1>(lhs) - std::get<1>(rhs)) <=
                      std::max(std::max(std::abs(std::get<1>(lhs)), std::abs(std::get<1>(rhs))) *
                                 threshold_ratio,
                               threshold_magnitude))
                   : false;
        }));
    }
  }

  return;
}

typedef struct CoarsenGraph_Usecase_t {
  std::string graph_file_full_path{};
  double coarsen_ratio{0.0};
  bool test_weighted{false};

  CoarsenGraph_Usecase_t(std::string const& graph_file_path,
                         double coarsen_ratio,
                         bool test_weighted)
    : coarsen_ratio(coarsen_ratio), test_weighted(test_weighted)
  {
    if ((graph_file_path.length() > 0) && (graph_file_path[0] != '/')) {
      graph_file_full_path = cugraph::test::get_rapids_dataset_root_dir() + "/" + graph_file_path;
    } else {
      graph_file_full_path = graph_file_path;
    }
  };
} CoarsenGraph_Usecase;

class Tests_CoarsenGraph : public ::testing::TestWithParam<CoarsenGraph_Usecase> {
 public:
  Tests_CoarsenGraph() {}
  static void SetupTestCase() {}
  static void TearDownTestCase() {}

  virtual void SetUp() {}
  virtual void TearDown() {}

  template <typename vertex_t, typename edge_t, typename weight_t, bool store_transposed>
  void run_current_test(CoarsenGraph_Usecase const& configuration)
  {
    raft::handle_t handle{};

    auto graph = cugraph::test::
      read_graph_from_matrix_market_file<vertex_t, edge_t, weight_t, store_transposed>(
        handle, configuration.graph_file_full_path, configuration.test_weighted);
    auto graph_view = graph.view();

    std::vector<vertex_t> h_labels(graph_view.get_number_of_vertices());
    auto num_labels = static_cast<vertex_t>(h_labels.size() * configuration.coarsen_ratio);
    ASSERT_TRUE(num_labels > 0);

    std::random_device r{};
    std::default_random_engine generator{r()};
    std::uniform_int_distribution<vertex_t> distribution{0, num_labels - 1};

    std::for_each(h_labels.begin(), h_labels.end(), [&distribution, &generator](auto& label) {
      label = distribution(generator);
    });

    rmm::device_uvector<vertex_t> d_labels(h_labels.size(), handle.get_stream());
    raft::update_device(d_labels.data(), h_labels.data(), h_labels.size(), handle.get_stream());

    CUDA_TRY(cudaStreamSynchronize(handle.get_stream()));

    std::unique_ptr<
      cugraph::experimental::graph_t<vertex_t, edge_t, weight_t, store_transposed, false>>
      coarse_graph{};
    rmm::device_uvector<vertex_t> coarse_vertices_to_labels(0, handle.get_stream());

    CUDA_TRY(cudaDeviceSynchronize());  // for consistent performance measurement

    std::tie(coarse_graph, coarse_vertices_to_labels) =
      cugraph::experimental::coarsen_graph(handle, graph_view, d_labels.begin());

    CUDA_TRY(cudaDeviceSynchronize());  // for consistent performance measurement

    std::vector<edge_t> h_org_offsets(graph_view.get_number_of_vertices() + 1);
    std::vector<vertex_t> h_org_indices(graph_view.get_number_of_edges());
    std::vector<weight_t> h_org_weights{};
    raft::update_host(h_org_offsets.data(),
                      graph_view.offsets(),
                      graph_view.get_number_of_vertices() + 1,
                      handle.get_stream());
    raft::update_host(h_org_indices.data(),
                      graph_view.indices(),
                      graph_view.get_number_of_edges(),
                      handle.get_stream());
    if (graph_view.is_weighted()) {
      h_org_weights.assign(graph_view.get_number_of_edges(), weight_t{0.0});
      raft::update_host(h_org_weights.data(),
                        graph_view.weights(),
                        graph_view.get_number_of_edges(),
                        handle.get_stream());
    }

    auto coarse_graph_view = coarse_graph->view();

    std::vector<edge_t> h_coarse_offsets(coarse_graph_view.get_number_of_vertices() + 1);
    std::vector<vertex_t> h_coarse_indices(coarse_graph_view.get_number_of_edges());
    std::vector<weight_t> h_coarse_weights{};
    raft::update_host(h_coarse_offsets.data(),
                      coarse_graph_view.offsets(),
                      coarse_graph_view.get_number_of_vertices() + 1,
                      handle.get_stream());
    raft::update_host(h_coarse_indices.data(),
                      coarse_graph_view.indices(),
                      coarse_graph_view.get_number_of_edges(),
                      handle.get_stream());
    if (graph_view.is_weighted()) {
      h_coarse_weights.resize(coarse_graph_view.get_number_of_edges());
      raft::update_host(h_coarse_weights.data(),
                        coarse_graph_view.weights(),
                        coarse_graph_view.get_number_of_edges(),
                        handle.get_stream());
    }

    std::vector<vertex_t> h_coarse_vertices_to_labels(h_coarse_vertices_to_labels.size());
    raft::update_host(h_coarse_vertices_to_labels.data(),
                      coarse_vertices_to_labels.data(),
                      coarse_vertices_to_labels.size(),
                      handle.get_stream());

    CUDA_TRY(cudaStreamSynchronize(handle.get_stream()));

    check_coarsened_graph_results(h_org_offsets.data(),
                                  h_org_indices.data(),
                                  h_org_weights.data(),
                                  h_labels.data(),
                                  h_coarse_offsets.data(),
                                  h_coarse_indices.data(),
                                  h_coarse_weights.data(),
                                  h_coarse_vertices_to_labels.data(),
                                  graph_view.get_number_of_vertices(),
                                  coarse_graph_view.get_number_of_vertices());
  }
};

// FIXME: add tests for type combinations
TEST_P(Tests_CoarsenGraph, CheckInt32Int32FloatFloat)
{
  run_current_test<int32_t, int32_t, float, false>(GetParam());
}

INSTANTIATE_TEST_CASE_P(
  simple_test,
  Tests_CoarsenGraph,
  ::testing::Values(CoarsenGraph_Usecase("test/datasets/karate.mtx", 0.2, false),
                    CoarsenGraph_Usecase("test/datasets/karate.mtx", 0.2, true),
                    CoarsenGraph_Usecase("test/datasets/web-Google.mtx", 0.1, false),
                    CoarsenGraph_Usecase("test/datasets/web-Google.mtx", 0.1, true),
                    CoarsenGraph_Usecase("test/datasets/ljournal-2008.mtx", 0.1, false),
                    CoarsenGraph_Usecase("test/datasets/ljournal-2008.mtx", 0.1, true),
                    CoarsenGraph_Usecase("test/datasets/webbase-1M.mtx", 0.1, false),
                    CoarsenGraph_Usecase("test/datasets/webbase-1M.mtx", 0.1, true)));

CUGRAPH_TEST_PROGRAM_MAIN()
