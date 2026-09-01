# 给 AGP 那条路用的。ndk-build 那条走同目录的 Android.mk，编的是同一个 hello.c。
cmake_minimum_required(VERSION 3.10)
project(hellonative C)
add_library(hellonative SHARED hello.c)
