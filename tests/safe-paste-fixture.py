#!/usr/bin/env python3
"""Delayed text-only clipboard substitute for isolated native input tests."""
import sys
import time

time.sleep(0.2)
sys.stdout.write("text/plain;charset=utf-8\n" if "--list-types" in sys.argv else "Safe paste")
