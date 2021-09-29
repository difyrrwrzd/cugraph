#=============================================================================
# Copyright (c) 2021, NVIDIA CORPORATION.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#=============================================================================

function(find_and_configure_cuco VERSION)

    rapids_cpm_find(cuco ${VERSION}
      GLOBAL_TARGETS cuco::cuco
      CPM_ARGS
        GIT_REPOSITORY https://github.com/NVIDIA/cuCollections.git
        GIT_TAG        a3c85ee2ea25ddfdd4596c6b9d546f7c7590743f
        OPTIONS        "BUILD_TESTS OFF"
                       "BUILD_BENCHMARKS OFF"
                       "BUILD_EXAMPLES OFF"
    )

    if(TARGET cuco AND NOT TARGET cuco::cuco)
      add_library(cuco::cuco ALIAS cuco)
    endif()

endfunction()

find_and_configure_cuco(0.0.1)
