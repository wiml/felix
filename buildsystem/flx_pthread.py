import fbuild
from fbuild.path import Path
from fbuild.record import Record
from fbuild.builders.file import copy

import buildsystem
from buildsystem.config import config_call

# ------------------------------------------------------------------------------

def build_runtime(phase):
    path = Path('src/pthread')

    buildsystem.copy_hpps_to_rtl(phase.ctx,
        phase.ctx.buildroot / 'config/target/flx_pthread_config.hpp',

        # portable
        path / 'pthread_thread.hpp',
        path / 'pthread_mutex.hpp',
        path / 'pthread_counter.hpp',
        path / 'pthread_waitable_bool.hpp',
        path / 'pthread_condv.hpp',
        path / 'pthread_semaphore.hpp',
        path / 'pthread_monitor.hpp',

        # win32 and posix
        path / 'pthread_win_posix_condv_emul.hpp',
    )

    dst = 'lib/rtl/flx_pthread'
    srcs = [copy(ctx=phase.ctx, src=f, dst=phase.ctx.buildroot / f) for f in [
        path / 'pthread_win_posix_condv_emul.cpp', # portability hackery
        path / 'pthread_mutex.cpp',
        path / 'pthread_condv.cpp',
        path / 'pthread_counter.cpp',
        path / 'pthread_waitable_bool.cpp',
        path / 'pthread_semaphore.cpp',
        path / 'pthread_monitor.cpp',
        path / 'pthread_thread_control.cpp',
        path / 'pthread_win_thread.cpp',
        path / 'pthread_posix_thread.cpp',
    ]]
    includes = [phase.ctx.buildroot / 'config/target', phase.ctx.buildroot / 'lib/rtl', 'src/rtl',]
    macros = ['BUILD_PTHREAD']
    flags = []
    libs = []
    external_libs = []

    pthread_h = config_call('fbuild.config.c.posix.pthread_h',
        phase.platform,
        phase.cxx.shared)

    if pthread_h.pthread_create:
        flags.extend(pthread_h.flags)
        libs.extend(pthread_h.libs)
        external_libs.extend(pthread_h.external_libs)

    return Record(
        static=buildsystem.build_cxx_static_lib(phase, dst, srcs,
            includes=includes,
            macros=macros,
            cflags=flags,
            libs=libs,
            external_libs=external_libs,
            lflags=flags),
        shared=buildsystem.build_cxx_shared_lib(phase, dst, srcs,
            includes=includes,
            macros=macros,
            cflags=flags,
            libs=libs,
            external_libs=external_libs,
            lflags=flags))

