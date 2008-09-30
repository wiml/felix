import fbuild
import fbuild.packages
import fbuild.packages.cxx as cxx
from fbuild.path import Path

# -----------------------------------------------------------------------------

def build_runtime(phase):
    path = Path('src/pthread')

    for hpp in (
            fbuild.buildroot / 'config/target/flx_pthread_config.hpp',

            # portable
            path / 'pthread_thread.hpp',
            path / 'pthread_mutex.hpp',
            path / 'pthread_counter.hpp',
            path / 'pthread_waitable_bool.hpp',
            path / 'pthread_condv.hpp',
            path / 'pthread_semaphore.hpp',
            path / 'pthread_monitor.hpp',
            path / 'pthread_sleep_queue.hpp',
            path / 'pthread_work_fifo.hpp',

            # win32 and posix
            path / 'pthread_win_posix_condv_emul.hpp'):
        fbuild.packages.Copy(fbuild.buildroot / 'lib/rtl', hpp).build()

    srcs = [
        path / 'pthread_win_posix_condv_emul.cpp', # portability hackery
        path / 'pthread_mutex.cpp',
        path / 'pthread_condv.cpp',
        path / 'pthread_counter.cpp',
        path / 'pthread_waitable_bool.cpp',
        path / 'pthread_semaphore.cpp',
        path / 'pthread_monitor.cpp',
        path / 'pthread_sleep_queue.cpp',
        path / 'pthread_work_fifo.cpp',
        path / 'pthread_thread_control.cpp',
    ]
    libs = []
    flags = []

    if 'win32' in phase.platform:
        srcs.append(path / 'pthread_win_thread.cpp')

    if 'posix' in phase.platform:
        srcs.append(path / 'pthread_posix_thread.cpp')

    if 'linux' in phase.platform:
        pass

    if 'bsd' in phase.platform:
        pass

    if 'solaris' in phase.platform:
        libs.append('rt')

    try:
        pthread_h = fbuild.env.cache('fbuild.builders.c.posix.config_pthread_h',
            phase.cxx.shared)
    except fbuild.builders.ConfigFailed:
        pass
    else:
        flags.extend(pthread_h.flags)

    return cxx.SharedLibrary(fbuild.buildroot / 'lib/rtl/flx_pthread_dynamic', srcs,
        includes=[fbuild.buildroot / 'config/target', 'src/rtl'],
        libs=libs,
        macros=['BUILD_PTHREAD'],
        lflags={'flags': flags},
        builder=phase.cxx)
