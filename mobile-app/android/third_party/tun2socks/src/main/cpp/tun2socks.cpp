#include <jni.h>
#include <string>
#include <cstdlib>
#include <cstdio>
#include <pthread.h>
#include <unistd.h>
#include <sys/resource.h>
#include <android/log.h>
#include <tun2socks/tun2socks.h>

/** Target fd limit to avoid "too many fds" (BReactor) when many SOCKS connections. Default Android ~1024. */
#define TUN2SOCKS_TARGET_FD_LIMIT 8192

// Start threads to redirect stdout and stderr to logcat.
int pipe_stdout[2];
int pipe_stderr[2];
pthread_t thread_stdout;
pthread_t thread_stderr;
const char *ADBTAG = "tun2socks";

void *thread_stderr_func(void *) {
    ssize_t redirect_size;
    char buf[2048];
    while ((redirect_size = read(pipe_stderr[0], buf, sizeof buf - 1)) > 0) {
        //__android_log will add a new line anyway.
        if (buf[redirect_size - 1] == '\n') {
            --redirect_size;
        }
        buf[redirect_size] = 0;
        __android_log_write(ANDROID_LOG_ERROR, ADBTAG, buf);
    }
    return 0;
}

void *thread_stdout_func(void *) {
    ssize_t redirect_size;
    char buf[2048];
    while ((redirect_size = read(pipe_stdout[0], buf, sizeof buf - 1)) > 0) {
        //__android_log will add a new line anyway.
        if (buf[redirect_size - 1] == '\n') {
            --redirect_size;
        }
        buf[redirect_size] = 0;
        __android_log_write(ANDROID_LOG_INFO, ADBTAG, buf);
    }
    return 0;
}

static int redirect_initialized = 0;

int start_redirecting_stdout_stderr() {
    // Запускаем перенаправление только один раз за процесс. При повторном вызове (reconnect)
    // не перезаписываем глобальные pipe и не создаём лишние потоки — иначе старые потоки
    // начинают читать из новых pipe и состояние ломается.
    if (redirect_initialized) {
        return 0;
    }
    redirect_initialized = 1;

    setvbuf(stdout, 0, _IONBF, 0);
    pipe(pipe_stdout);
    dup2(pipe_stdout[1], STDOUT_FILENO);

    setvbuf(stderr, 0, _IONBF, 0);
    pipe(pipe_stderr);
    dup2(pipe_stderr[1], STDERR_FILENO);

    if (pthread_create(&thread_stdout, 0, thread_stdout_func, 0) == -1) {
        redirect_initialized = 0;
        return -1;
    }
    pthread_detach(thread_stdout);

    if (pthread_create(&thread_stderr, 0, thread_stderr_func, 0) == -1) {
        redirect_initialized = 0;
        return -1;
    }
    pthread_detach(thread_stderr);

    return 0;
}

extern "C"
JNIEXPORT jint JNICALL
Java_com_LondonX_tun2socks_Tun2Socks_start_1tun2socks(JNIEnv *env, jclass clazz,
                                                                   jobjectArray args) {
    //argc
    jsize argument_count = env->GetArrayLength(args);

    //Compute byte size need for all arguments in contiguous memory.
    int c_arguments_size = 0;
    for (int i = 0; i < argument_count; i++) {
        c_arguments_size += strlen(
                env->GetStringUTFChars((jstring) env->GetObjectArrayElement(args, i), 0));
        c_arguments_size++; // for '\0'
    }

    //Stores arguments in contiguous memory.
    char *args_buffer = (char *) calloc(c_arguments_size, sizeof(char));

    //argv to pass into tun2socks.
    char *argv[argument_count];

    //To iterate through the expected start position of each argument in args_buffer.
    char *current_args_position = args_buffer;

    //Populate the args_buffer and argv.
    for (int i = 0; i < argument_count; i++) {
        const char *current_argument = env->GetStringUTFChars(
                (jstring) env->GetObjectArrayElement(args, i), 0);

        //Copy current argument to its expected position in args_buffer
        strncpy(current_args_position, current_argument, strlen(current_argument));

        //Save current argument start position in argv
        argv[i] = current_args_position;

        //Increment to the next argument's expected position.
        current_args_position += strlen(current_args_position) + 1;
    }

    //Start threads to show stdout and stderr in logcat.
    if (start_redirecting_stdout_stderr() == -1) {
        __android_log_write(ANDROID_LOG_ERROR, ADBTAG,
                            "Couldn't start redirecting stdout and stderr to logcat.");
    }

    // Raise RLIMIT_NOFILE to avoid "too many fds" (BReactor) when many SOCKS connections.
    struct rlimit rl;
    if (getrlimit(RLIMIT_NOFILE, &rl) == 0) {
        struct rlimit new_rl;
        new_rl.rlim_cur = (TUN2SOCKS_TARGET_FD_LIMIT < (long)rl.rlim_max)
            ? TUN2SOCKS_TARGET_FD_LIMIT : rl.rlim_max;
        new_rl.rlim_max = rl.rlim_max;
        if (setrlimit(RLIMIT_NOFILE, &new_rl) == 0) {
            char msg[64];
            snprintf(msg, sizeof(msg), "Raised RLIMIT_NOFILE to %ld", (long)new_rl.rlim_cur);
            __android_log_write(ANDROID_LOG_INFO, ADBTAG, msg);
        }
    }

    //Start tun2socks, with argc and argv.
    int result = tun2socks_start(argument_count, argv);
    free(args_buffer);

    return jint(result);
}

extern "C"
JNIEXPORT void JNICALL
Java_com_LondonX_tun2socks_Tun2Socks_stopTun2Socks(JNIEnv *env, jclass clazz) {
    tun2socks_terminate();
}

extern "C"
JNIEXPORT void JNICALL
Java_com_LondonX_tun2socks_Tun2Socks_printTun2SocksHelp(JNIEnv *env, jclass clazz) {
    tun2socks_print_help("badvpn-tun2socks");
}

extern "C"
JNIEXPORT void JNICALL
Java_com_LondonX_tun2socks_Tun2Socks_printTun2SocksVersion(JNIEnv *env, jclass clazz) {
    tun2socks_print_version();
}