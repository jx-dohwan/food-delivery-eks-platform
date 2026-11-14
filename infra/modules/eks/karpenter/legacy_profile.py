#!/usr/bin/env python3
"""Derive Karpenter's legacy profile name without AWS access or stored hashes.

Pinned Karpenter v1.14.1 hashes the UTF-8 string region + EC2NodeClass name
with hashstructure/v2's default FNV-1 64-bit hasher (not FNV-1a):
https://github.com/aws/karpenter-provider-aws/blob/v1.14.1/pkg/apis/v1/ec2nodeclass.go
https://github.com/mitchellh/hashstructure/blob/v2.0.2/hashstructure.go
"""
import json
import sys


def legacy_profile_name(cluster_name, region, node_class_name):
    value = 14695981039346656037  # FNV-1 64-bit offset basis
    for byte in (region + node_class_name).encode('utf-8'):
        value = ((value * 1099511628211) & ((1 << 64) - 1)) ^ byte
    return f'{cluster_name}_{value}'


if __name__ == '__main__':
    query = json.load(sys.stdin)
    name = legacy_profile_name(query['cluster_name'], query['region'], query['node_class_name'])
    json.dump({'name': name}, sys.stdout)
