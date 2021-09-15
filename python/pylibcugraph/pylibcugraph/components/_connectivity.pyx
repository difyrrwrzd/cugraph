# Copyright (c) 2021, NVIDIA CORPORATION.
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

from libc.stdint cimport uintptr_t
from libcpp.memory cimport unique_ptr

from pylibcugraph.components._connectivity cimport *


def _ensure_arg_types(**kwargs):
    """
    Ensure all args have a __cuda_array_interface__ attr
    """
    for (arg_name, arg_val) in kwargs.items():
        # FIXME: remove this special case when weights are supported: weights
        # can only be None
        if arg_name is "weights":
            if arg_val is not None:
                raise TypeError("weights are currently not supported and must "
                                "be None")

        elif not(hasattr(arg_val, "__cuda_array_interface__")):
            raise TypeError(f"{arg_name} must support __cuda_array_interface__")

        if arg_name in ["offsets", "indices", "labels"]:
            typestr = arg_val.__cuda_array_interface__.get("typestr")
            if typestr != "<i4":
                raise TypeError(f"{arg_name} array must have a dtype of int32")


def strongly_connected_components(offsets, indices, weights, num_verts, num_edges, labels):
    """
    This is the docstring for strongly_connected_components
    FIXME: write this docstring
    """
    _ensure_arg_types(offsets=offsets, indices=indices,
                      weights=weights, labels=labels)

    cdef unique_ptr[handle_t] handle_ptr
    handle_ptr.reset(new handle_t())
    handle_ = handle_ptr.get()

    cdef uintptr_t c_offsets = offsets.__cuda_array_interface__['data'][0]
    cdef uintptr_t c_indices = indices.__cuda_array_interface__['data'][0]
    cdef uintptr_t c_edge_weights = <uintptr_t>NULL
    cdef uintptr_t c_labels = labels.__cuda_array_interface__['data'][0]

    cdef GraphCSRView[int,int,float] g

    g = GraphCSRView[int,int,float](<int*>c_offsets, <int*>c_indices, <float*>NULL, num_verts, num_edges)

    cdef cugraph_cc_t connect_type=CUGRAPH_STRONG
    connected_components(g, <cugraph_cc_t>connect_type, <int *>c_labels)


def weakly_connected_components(offsets, indices, weights, num_verts, num_edges, labels):
    """
    This is the docstring for weakly_connected_components
    FIXME: write this docstring
    """
    _ensure_arg_types(offsets=offsets, indices=indices,
                      weights=weights, labels=labels)

    cdef unique_ptr[handle_t] handle_ptr
    handle_ptr.reset(new handle_t())
    handle_ = handle_ptr.get()

    cdef uintptr_t c_offsets = offsets.__cuda_array_interface__['data'][0]
    cdef uintptr_t c_indices = indices.__cuda_array_interface__['data'][0]
    cdef uintptr_t c_edge_weights = <uintptr_t>NULL
    cdef uintptr_t c_labels = labels.__cuda_array_interface__['data'][0]

    cdef GraphCSRView[int,int,float] g

    g = GraphCSRView[int,int,float](<int*>c_offsets, <int*>c_indices, <float*>NULL, num_verts, num_edges)

    cdef cugraph_cc_t connect_type=CUGRAPH_WEAK
    connected_components(g, <cugraph_cc_t>connect_type, <int *>c_labels)
