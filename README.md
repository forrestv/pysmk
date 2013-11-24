Cython/Python Smacker video decoder
============================

PySMK is a video decoder written in Cython. It uses PyGame for video and audio.


Documentation
-------------


pysmk.SMKReader(file): return SMKReader

Reads the header and first frame of the Smacker video contained in file.
file - any file-like object


pysmk.SMKReader.next(): return None

Advances SMKReader to next frame.


pysmk.SMKReader.frames

Integer of number of frames.


pysmk.SMKReader.fps

Float of frames per second.


pysmk.SMKReader.video

pygame.Surface of current frame.


pysmk.SMKReader.audio

List of pygame.mixer.Sound's representing audio streams in file.
