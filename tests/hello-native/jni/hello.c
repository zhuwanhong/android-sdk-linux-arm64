#include <jni.h>
#include <stdio.h>

// 这个函数存在的唯一目的：证明 NDK 的 host 工具链真的编出了能在手机上跑的
// 原生代码。返回值里带上编译期常量，好确认跑的是新编的这份而不是旧产物。
JNIEXPORT jstring JNICALL
Java_com_example_hellonative_MainActivity_stringFromNative(JNIEnv *env, jobject thiz) {
    char buf[128];
    snprintf(buf, sizeof buf, "native ok: %d-bit, built %s",
             (int)(sizeof(void *) * 8), __DATE__);
    return (*env)->NewStringUTF(env, buf);
}

// 再验一点点真实计算，免得「能加载」被误当成「能干活」
JNIEXPORT jint JNICALL
Java_com_example_hellonative_MainActivity_addNative(JNIEnv *env, jobject thiz,
                                                   jint a, jint b) {
    return a + b;
}
