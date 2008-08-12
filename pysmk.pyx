# Cython Smacker video decoder

# TODO
#   Enable caching of header & trees (make seperate SMKPlayer object) ?
#   Other audio support
#   Y doubling/interlacing
#   Implement hackish sound streamer

cdef extern from "inttypes.h":
    ctypedef signed int int32_t
    ctypedef unsigned int uint32_t
    ctypedef signed short int16_t
    ctypedef unsigned short uint16_t
    ctypedef signed char int8_t
    ctypedef unsigned char uint8_t

cdef extern from "string.h":
    void *memcpy(void *dest, void *src, uint32_t n)

cdef extern from "stdlib.h":
    void *malloc(uint32_t size)

cdef extern from "byteswap.h":
    uint16_t bswap_16(uint16_t n)

cdef extern from "Python.h":
    void* PyMem_Malloc(uint32_t n)
    void PyMem_Free(void *p)
    uint32_t PyString_AsStringAndSize(object obj, char **buffer, uint32_t *length) except -1

cdef extern from "object.h":
    ctypedef class __builtin__.object [object PyObject]:
        pass

cdef extern from "pyerrors.h":
    ctypedef class __builtin__.Exception [object PyBaseExceptionObject]:
        pass

cdef extern from "SDL/SDL_video.h":
    struct SDL_Surface:
        void *pixels

cdef extern from "SDL/SDL_mixer.h":
    struct Mix_Chunk:
        uint32_t allocated
        uint8_t *abuf
        uint32_t alen
        uint8_t volume
    void import_pygame_mixer()

cdef extern from "pygame/pygame.h":
    SDL_Surface *PySurface_AsSurface(object x)

cdef extern from "pygame/mixer.h":
    object PySound_New(Mix_Chunk *chunk)

import pygame

import_pygame_mixer()

cdef class FormatError(Exception):
    pass

cdef class SMKReader(object):
    cdef readonly uint32_t frames
    cdef readonly double fps
    cdef readonly object video
    cdef readonly object audio
    
    cdef uint32_t width
    cdef uint32_t height
    cdef uint32_t ring_frame
    cdef uint32_t audio_size[7]
    cdef uint32_t audio_rate[7]
    cdef uint32_t *frame_size
    cdef uint8_t *frame_type
    
    cdef uint32_t pal[256]
    
    cdef uint32_t frame_start
    cdef uint32_t frameno
    
    cdef object file
    cdef object buffer
    cdef char *bbuffer
    cdef uint32_t blen
    cdef uint32_t bpos
    
    cdef uint32_t *mmap_tree
    cdef uint32_t *mclr_tree
    cdef uint32_t *full_tree
    cdef uint32_t *type_tree
    
    cdef uint32_t *pixels
    cdef Mix_Chunk *audio_chunk[7]
    cdef uint32_t audio_pos[7]
    
    cdef void _set_buffer(self, uint32_t l) except *:
        s = self.file.read(l)
        self.buffer = s
        PyString_AsStringAndSize(s, &self.bbuffer, &self.blen)
        if self.blen != l:
            raise ValueError, "early EOF"
        self.bpos = 0
    
    cdef uint8_t _read_bit(self) except? 67:
        cdef uint8_t res
        res = (self.bbuffer[self.bpos >> 3] >> (self.bpos&7)) & 1
        self.bpos = self.bpos + 1
        return res
    
    cdef uint8_t _read_byte(self) except? 67:
        cdef uint8_t res
        if self.bpos & 7:
            res = self._read_bit()
            res = res + (self._read_bit()<<1)
            res = res + (self._read_bit()<<2)
            res = res + (self._read_bit()<<3)
            res = res + (self._read_bit()<<4)
            res = res + (self._read_bit()<<5)
            res = res + (self._read_bit()<<6)
            res = res + (self._read_bit()<<7)
        else:
            res = self.bbuffer[self.bpos >> 3]
            self.bpos = self.bpos + 8
        return res
    
    cdef uint16_t _read_short(self) except? 67:
        cdef uint16_t res
        res = self._read_byte()
        res = res + (self._read_byte()<<8)
        return res
    
    cdef uint32_t _read_int(self) except? 67:
        cdef uint32_t res
        res = self._read_byte()
        res = res + (self._read_byte()<<8)
        res = res + (self._read_byte()<<16)
        res = res + (self._read_byte()<<24)
        return res
    
    cdef uint32_t _read_little_node(self, uint32_t *tree, uint32_t *last) except? 67:
        cdef uint32_t me = last[0]
        last[0] = last[0] + 1
        if self._read_bit():
            self._read_little_node(tree, last)
            tree[me] = 0x80000000 + self._read_little_node(tree, last)
        else:
            tree[me] = self._read_byte()
        return me
    
    cdef uint32_t *_read_little_tree(self) except? NULL:
        cdef uint32_t *tree = <uint32_t*>PyMem_Malloc(sizeof(uint32_t)*256*8)
        cdef uint32_t last = 0
        self._read_bit()
        self._read_little_node(tree, &last)
        self._read_bit()
        return tree
    
    cdef uint8_t _decompress_little(self, uint32_t *tree) except? 67:
        cdef uint32_t cur = 0
        while tree[cur] & 0x80000000:
            if self._read_bit():
                cur = tree[cur] & 0x7fffffff
            else:
                cur = cur + 1
        return tree[cur]
    
    cdef uint32_t _read_main_node(self, uint32_t *tree, uint32_t *last, uint32_t *low, uint32_t *high, uint32_t *shorts) except? 67:
        cdef uint32_t me = last[0]
        cdef uint32_t lowv, highv
        cdef uint32_t i
        last[0] = last[0] + 1
        if self._read_bit():
            self._read_main_node(tree, last, low, high, shorts)
            tree[me] = 0x80000000 + self._read_main_node(tree, last, low, high, shorts)
        else:
            lowv = self._decompress_little(low)
            highv = self._decompress_little(high)
            tree[me] = (highv<<8) + lowv
            for i from 0 <= i < 3:
                if tree[me] == shorts[i]:
                    assert tree[i] == 0, "multiple shorts"
                    tree[i] = me
        return me
    
    cdef uint32_t *_read_main_tree(self, uint32_t tree_size) except? NULL:
        cdef uint32_t *high
        cdef uint32_t *low
        cdef uint32_t *tree
        cdef uint32_t last
        
        if not self._read_bit():
            return NULL
        
        tree_size = 2*tree_size + 128 # doesn't seem exact, need 4 more
        
        low = self._read_little_tree()
        high = self._read_little_tree()
        
        tree = <uint32_t*>PyMem_Malloc(tree_size*sizeof(uint32_t))
        
        cdef uint32_t shorts[3]
        cdef uint32_t i
        for i from 0 <= i < 3:
            tree[i] = 0
            shorts[i] = self._read_short()
        
        last = 3
        self._read_main_node(tree, &last, low, high, shorts)
        self._read_bit()
        
        PyMem_Free(high)
        PyMem_Free(low)
        
        for i from 0 <= i < 3:
            if tree[i] == 0:
                tree[i] = last
                last = last + 1
        return tree
    
    cdef uint16_t _decompress_short(self, uint32_t *tree) except? 67:
        cdef uint32_t cur = 3
        while tree[cur] & 0x80000000:
            if self._read_bit():
                cur = tree[cur] & 0x7fffffff
            else:
                cur = cur+1
        val = tree[cur]
        if tree[tree[0]] != val:
            tree[tree[2]] = tree[tree[1]]
            tree[tree[1]] = tree[tree[0]]
            tree[tree[0]] = val
        return val
    
    cdef void _clear_lasts(self, uint32_t *tree) except *:
        cdef uint32_t i
        for i from 0 <= i < 3:
            tree[tree[i]] = 0
    
    def __init__(self, file):
        self.file = file
        
        self._set_buffer(104)
        
        cdef int32_t framerate
        cdef uint32_t i
        cdef uint32_t trees_size, mmap_size, mclr_size, full_size, type_size
        if self._read_int() != 843795795:
            raise FormatError, "not a Smacker video"
        self.width = self._read_int()
        self.height = self._read_int()
        self.frames = self._read_int()
        framerate = self._read_int()
        if framerate > 0:
            self.fps = 1000. / framerate
        elif framerate < 0:
            self.fps = 100000. / (-framerate)
        else:
            self.fps = 10.
        self.ring_frame = self._read_int() & 1 # TODO: y doubling/interlacing
        for i from 0 <= i < 7:
            self.audio_size[i] = self._read_int()
        trees_size = self._read_int()
        mmap_size = self._read_int()
        mclr_size = self._read_int()
        full_size = self._read_int()
        type_size = self._read_int()
        for i from 0 <= i < 7:
            self.audio_rate[i] = self._read_int()
        self._read_int()
        
        if self.ring_frame:
            self.frames = self.frames + 1
        
        self._set_buffer(self.frames*4+self.frames+trees_size)
        
        self.frame_size = <uint32_t *>PyMem_Malloc(self.frames*4)
        for i from 0 <= i < self.frames:
            self.frame_size[i] = self._read_int() & (~3)
        
        self.frame_type = <uint8_t *>PyMem_Malloc(self.frames)
        for i from 0 <= i < self.frames:
            self.frame_type[i] = self._read_byte()
        
        self.mmap_tree = self._read_main_tree(mmap_size)
        self.mclr_tree = self._read_main_tree(mclr_size)
        self.full_tree = self._read_main_tree(full_size)
        self.type_tree = self._read_main_tree(type_size)
        
        self.video = pygame.surface.Surface((self.width,self.height), pygame.SRCALPHA if self.ring_frame else 0, 32) # TODO: alpha
        self.pixels = <uint32_t*>PySurface_AsSurface(self.video).pixels
        
        cdef object audios = []
        cdef Mix_Chunk *chunk
        cdef uint8_t *sound
        cdef uint32_t length
        for i from 0 <= i < 7:
            if self.audio_rate[i] & 0x40000000:
                length = self.audio_size[i]*self.frames
                sound = <uint8_t*>malloc(length)
                chunk = <Mix_Chunk*>malloc(sizeof(Mix_Chunk))
                chunk.allocated = 1
                chunk.alen = length
                chunk.abuf = sound
                chunk.volume = 128
                audio = PySound_New(chunk)
                self.audio_chunk[i] = chunk
                self.audio_pos[i] = 0
            else:
                audio = None
                self.audio_chunk[i] = NULL
            audios.append(audio)
        self.audio = tuple(audios)
        
        self.frame_start = self.file.tell()
        
        self.frameno = 0
        self.next()
    
    cdef void _read_palette(self) except *:
        cdef uint32_t oldpal[256]
        memcpy(oldpal, self.pal, 256*4)
        
        cdef uint32_t l = self._read_byte()*4
        cdef uint8_t a, b, c
        cdef uint32_t i, pp = 0
        
        while True:
            a = self._read_byte()
            if a & 0x80:
                pp = pp + (a & 0x7f) + 1
            elif a & 0x40:
                b = self._read_byte()
                c = (a & 0x3f) + 1
                memcpy(self.pal+4*pp, oldpal+4*b, c*4)
                pp = pp + c
            else:
                b = self._read_byte()
                c = self._read_byte()
                self.pal[pp] = (255 << 24) + (((a << 2) + (b >> 4)) << 16) + (((b << 2) + (b >> 4)) << 8) + ((c << 2) + (c >> 4))
                pp = pp + 1
            if pp == 256:
                break
            assert pp < 256, "read too much palette data"
        
        self.bpos = l*8
        
        if self.ring_frame:
            self.pal[0] = 0
    
    cdef void _read_audio(self, uint32_t index) except *:
        cdef uint32_t i, j, start = self.bpos
        cdef uint32_t *tree[4]
        cdef uint16_t val[2]
        cdef int16_t new
        
        cdef int16_t *buf = <int16_t*>(self.audio_chunk[index].abuf + self.audio_pos[index])
        
        cdef uint32_t astart = self.audio_pos[index]
        
        cdef uint32_t l = self._read_int()
        assert self.audio_rate[index] & 0x80000000, "audio not supported" # TODO: other audio support
        cdef uint32_t uncompressed_size = self._read_int()
        assert uncompressed_size % 4 == 0, "odd audio size"
        assert self._read_bit(), "no audio?"
        assert self._read_bit(), "audio not supported"
        assert self._read_bit(), "audio not supported"
        
        for i from 0 <= i < 4:
            tree[i] = self._read_little_tree()
        for i from 0 <= i < 2:
            val[1-i] = bswap_16(self._read_short())
            buf[i] = val[1-i]
        for j from 2 <= j < uncompressed_size/2:
            #for i from 0 <= i < 2:
                new = self._decompress_little(tree[2*(j%2)]) | (self._decompress_little(tree[2*(j%2)+1]) << 8)
                val[j%2] += new
                buf[j] = val[j%2]
        
        for i from 0 <= i < 4:
            PyMem_Free(tree[i])
        
        self.audio_pos[index] += uncompressed_size
        #print ((start+l*8)-self.bpos)/8.
        self.bpos = start + l*8
    
    cdef void _read_video(self) except *:
        cdef uint16_t type, length, extra, ra, rb
        cdef uint32_t place = 0
        cdef uint32_t px, py, tx, ty, i
        cdef uint32_t sx = (self.width + 3) >> 2
        cdef uint32_t sy = (self.height + 3) >> 2
        while True:
            type = self._decompress_short(self.type_tree)
            length = (type >> 2) & 63
            if length > 58:
                length = 128 << (length - 59)
            else:
                length = length + 1
            extra = type >> 8
            type = type & 3
            for i from 0 <= i < length:
                px = (place % sx)*4
                py = (place / sx)*4
                if type == 0:
                    ra = self._decompress_short(self.mclr_tree)
                    rb = self._decompress_short(self.mmap_tree)
                    for ty from 0 <= ty < 4:
                        for tx from 0 <= tx < 4:
                            if (rb >> (tx+4*ty)) & 1:
                                self.pixels[px+tx+self.width*(py+ty)] = self.pal[ra>>8]
                            else:
                                self.pixels[px+tx+self.width*(py+ty)] = self.pal[ra&255]
                elif type == 1:
                    for ty from 0 <= ty < 4:
                        ra = self._decompress_short(self.full_tree)
                        self.pixels[px+2+self.width*(py+ty)] = self.pal[ra&255]
                        self.pixels[px+3+self.width*(py+ty)] = self.pal[ra>>8]
                        rb = self._decompress_short(self.full_tree)
                        self.pixels[px+0+self.width*(py+ty)] = self.pal[rb&255]
                        self.pixels[px+1+self.width*(py+ty)] = self.pal[rb>>8]
                elif type == 2:
                    pass
                elif type == 3:
                    for ty from 0 <= ty < 4:
                        for tx from 0 <= tx < 4:
                            self.pixels[px+tx+self.width*(py+ty)] = self.pal[extra]
                place = place + 1
                if place >= sx*sy: break
            if place >= sx*sy: break
    
    def next(self):
        if self.frameno == self.frames:
            if self.ring_frame:
                self.frameno = 0
                self.file.seek(self.frame_start)
                self.next() # read ring frame
            else:
                raise StopIteration
        
        self._set_buffer(self.frame_size[self.frameno])
        
        if self.frame_type[self.frameno] & 1:
            self._read_palette()
        
        cdef uint32_t i
        for i from 0 <= i < 7:
            if self.frame_type[self.frameno] & (2 << i):
                self._read_audio(i)
        
        self._clear_lasts(self.mclr_tree)
        self._clear_lasts(self.mmap_tree)
        self._clear_lasts(self.full_tree)
        self._clear_lasts(self.type_tree)
        
        self._read_video()
        
        self.frameno = self.frameno + 1
    
    def __dealloc__(self):
        PyMem_Free(self.frame_size)
        PyMem_Free(self.frame_type)
        PyMem_Free(self.mmap_tree)
        PyMem_Free(self.mclr_tree)
        PyMem_Free(self.full_tree)
        PyMem_Free(self.type_tree)
        # audio is freed by SDL
