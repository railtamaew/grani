#!/bin/bash
/usr/bin/docker ps --format "table {{.Names}}\t{{.Image}}\t{{.Status}}"
