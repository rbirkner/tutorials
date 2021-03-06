/* Copyright 2013-present Barefoot Networks, Inc.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *   http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#include "includes/headers.p4"
#include "includes/parser.p4"

// heavy hitter threshold after which action is triggered
#define HEAVY_HITTER_THRESHOLD 100

field_list ipv4_checksum_list {
        ipv4.version;
        ipv4.ihl;
        ipv4.diffserv;
        ipv4.totalLen;
        ipv4.identification;
        ipv4.flags;
        ipv4.fragOffset;
        ipv4.ttl;
        ipv4.protocol;
        ipv4.srcAddr;
        ipv4.dstAddr;
}

field_list_calculation ipv4_checksum {
    input {
        ipv4_checksum_list;
    }
    algorithm : csum16;
    output_width : 16;
}

calculated_field ipv4.hdrChecksum  {
    verify ipv4_checksum;
    update ipv4_checksum;
}

action _drop() {
    drop();
}

header_type custom_metadata_t {
    fields {
        nhop_ipv4: 32;
        // additional fields for the hash values and the counter values
        index_1: 32;
        index_2: 32;
        counter_1: 32;
        counter_2: 32;
    }
}

metadata custom_metadata_t custom_metadata;

action set_nhop(nhop_ipv4, port) {
    modify_field(custom_metadata.nhop_ipv4, nhop_ipv4);
    modify_field(standard_metadata.egress_spec, port);
    add_to_field(ipv4.ttl, -1);
}

action set_dmac(dmac) {
    modify_field(ethernet.dstAddr, dmac);
}

// field list for the bloom filter hashes
field_list heavy_hitter_list {
        ipv4.srcAddr;
        ipv4.dstAddr;
        tcp.srcPort;
        tcp.dstPort;
        ipv4.protocol;
}

// hash functions for counting
field_list_calculation heavy_hitter_hash_1 {
    input {
        heavy_hitter_list;
    }
    algorithm: csum16;
    output_width: 16;
}

field_list_calculation heavy_hitter_hash_2 {
    input {
        heavy_hitter_list;
    }
    algorithm: crc16;
    output_width: 16;
}

// Define the registers to store the counts
register heavy_hitter_bf {
    width: 32;
    instance_count: 1024;
}

// Actions to set heavy hitter filter
action update_hash() {
    // compute the indexes of the counters
    modify_field_with_hash_based_offset(custom_metadata.index_1, 0, heavy_hitter_hash_1, 1024);
    modify_field_with_hash_based_offset(custom_metadata.index_2, 0, heavy_hitter_hash_2, 1024);

    // read current counter values
    register_read(custom_metadata.counter_1, heavy_hitter_bf, custom_metadata.index_1);
    register_read(custom_metadata.counter_2, heavy_hitter_bf, custom_metadata.index_2);

    // update the counters
    add_to_field(custom_metadata.counter_1, 1);
    add_to_field(custom_metadata.counter_2, 1);

    // write back to the register
    register_write(heavy_hitter_bf, custom_metadata.index_1, custom_metadata.counter_1);
    register_write(heavy_hitter_bf, custom_metadata.index_2, custom_metadata.counter_2);
}

// Define the tables to run actions
table heavy_hitter_update {
    actions {
        update_hash;
    }
    size: 1024;
}

// Define table to drop the heavy hitter traffic
table heavy_hitter_filter {
    actions {
        _drop;
    }
    size: 1024;
}

table ipv4_lpm {
    reads {
        ipv4.dstAddr : lpm;
    }
    actions {
        set_nhop;
        _drop;
    }
    size: 1024;
}

table forward {
    reads {
        custom_metadata.nhop_ipv4 : exact;
    }
    actions {
        set_dmac;
        _drop;
    }
    size: 512;
}

action rewrite_mac(smac) {
    modify_field(ethernet.srcAddr, smac);
}

table send_frame {
    reads {
        standard_metadata.egress_port: exact;
    }
    actions {
        rewrite_mac;
        _drop;
    }
    size: 256;
}

control ingress {
    apply(heavy_hitter_update);
    if (custom_metadata.counter_1 > HEAVY_HITTER_THRESHOLD and custom_metadata.counter_2 > HEAVY_HITTER_THRESHOLD) {
        apply(heavy_hitter_filter);
    } else {
        apply(ipv4_lpm);
        apply(forward);
    }
}

control egress {
    apply(send_frame);
}
