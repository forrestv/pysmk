from distutils.core import setup
from distutils.extension import Extension
from Cython.Distutils import build_ext

setup(
    name = "pysmk",
    ext_modules=[
        Extension("pysmk", ["pysmk.pyx"],
        include_dirs=["/usr/include/SDL"],
        extra_compile_args=["-O3","-funroll-loops"],
        libraries=["SDL_mixer"],
        ),
    ],
    cmdclass = {'build_ext': build_ext},
)
