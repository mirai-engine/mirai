#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["yt-dlp>=2026.10.26", "pillow>=13"]
# [tool.uv]
# required-version = ">=0.13"
# ///
"""Reference frames from a video, to compare with Mirai captures. The videos and frames are private:
they stay in .mirai/tmp/video_frames of the checkout, which git ignores, and are never committed.

    uv run scripts/video_frames.py <url or file> --start 22 --end 28 [--fps 10 | --every 0.1]
        [--columns 6] [--width 480] [--out <folder>] [--audio] [--item 1]

Windows only. Works with any site yt-dlp supports that serves H.264 and AAC over https (YouTube,
X posts, ...); --item picks a video of a post with several. yt-dlp only resolves the streams (best
H.264 up to 1080p on the short side); the decoders of Windows (Media Foundation) read just the
section from them with byte ranges, without FFmpeg and without downloading the whole video. The
fragmented MP4 of YouTube, which Media Foundation does not read, is cut to the segments of the
section, turned into a plain MP4 and kept in cache/ by video id. Writes:
  - <out>/frames/<time>.png: the frame shown every 1/fps seconds, at its original size;
  - <out>/strip.png: a grid of those frames scaled to --width, each labelled with its time in
    seconds, like the filmstrips of play.capture;
  - with --audio, <out>/audio.wav (mono 48 kHz) of the same section, for comparing sounds.
Prints the paths as JSON.

The GUIDs, constants and vtable orders of Media Foundation are those of windows-rs (MIT)."""
import argparse
import ctypes as C
import json
import os
import re
import struct
import sys
import wave

from PIL import Image, ImageDraw, ImageFont

WORK = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), '.mirai', 'tmp', 'video_frames')


class GUID(C.Structure):
    _fields_ = [('a', C.c_uint32), ('b', C.c_uint16), ('c', C.c_uint16), ('d', C.c_ubyte * 8)]


def _guid(a, b, c, *d):
    return GUID(a, b, c, (C.c_ubyte * 8)(*d))


def _media_guid(n):
    return _guid(n, 0x0000, 0x0010, 0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71)


class PROPVARIANT(C.Structure):  # only the VT_I8 member is used; 24 bytes on 64-bit like the real one
    _fields_ = [('vt', C.c_ushort), ('r1', C.c_ushort), ('r2', C.c_ushort), ('r3', C.c_ushort),
                ('value', C.c_longlong), ('pad', C.c_longlong)]


GUID_NULL = GUID()
MF_SOURCE_READER_ENABLE_VIDEO_PROCESSING = _guid(0xfb394f3d, 0xccf1, 0x42ee, 0xbb, 0xb3, 0xf9, 0xb8, 0x45, 0xd5, 0x68, 0x1d)
MF_MT_MAJOR_TYPE = _guid(0x48eba18e, 0xf8c9, 0x4687, 0xbf, 0x11, 0x0a, 0x74, 0xc9, 0xf9, 0x6a, 0x8f)
MF_MT_SUBTYPE = _guid(0xf7e34c9a, 0x42e8, 0x4714, 0xb7, 0x4b, 0xcb, 0x29, 0xd7, 0x2c, 0x35, 0xe5)
MF_MT_FRAME_SIZE = _guid(0x1652c33d, 0xd6b2, 0x4012, 0xb8, 0x34, 0x72, 0x03, 0x08, 0x49, 0xa3, 0x7d)
MF_MT_DEFAULT_STRIDE = _guid(0x644b4e48, 0x1e02, 0x4516, 0xb0, 0xeb, 0xc0, 0x1c, 0xa9, 0xd4, 0x9a, 0xc6)
MF_MT_MINIMUM_DISPLAY_APERTURE = _guid(0xd7388766, 0x18fe, 0x48c6, 0xa1, 0x77, 0xee, 0x89, 0x48, 0x67, 0xc8, 0xc4)
MF_MT_AUDIO_NUM_CHANNELS = _guid(0x37e48bf5, 0x645e, 0x4c5b, 0x89, 0xde, 0xad, 0xa9, 0xe2, 0x9b, 0x69, 0x6a)
MF_MT_AUDIO_SAMPLES_PER_SECOND = _guid(0x5faeeae7, 0x0290, 0x4c31, 0x9e, 0x8a, 0xc5, 0x34, 0xf6, 0x8d, 0x9d, 0xba)
MF_MT_AUDIO_BITS_PER_SAMPLE = _guid(0xf2deb57f, 0x40fa, 0x4764, 0xaa, 0x33, 0xed, 0x4f, 0x2d, 0x1f, 0xf6, 0x69)
MF_MT_AUDIO_BLOCK_ALIGNMENT = _guid(0x322de230, 0x9eeb, 0x43bd, 0xab, 0x7a, 0xff, 0x41, 0x22, 0x51, 0x54, 0x1d)
MF_MT_AUDIO_AVG_BYTES_PER_SECOND = _guid(0x1aab75c8, 0xcfef, 0x451c, 0xab, 0x95, 0xac, 0x03, 0x4b, 0x8e, 0x17, 0x31)
MFMediaType_Video = _guid(0x73646976, 0x0000, 0x0010, 0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71)
MFMediaType_Audio = _guid(0x73647561, 0x0000, 0x0010, 0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71)
MFVideoFormat_RGB32 = _media_guid(22)  # D3DFMT_X8R8G8B8: B, G, R, X in memory
MFAudioFormat_Float = _media_guid(3)   # WAVE_FORMAT_IEEE_FLOAT
IID_IMF2DBuffer = _guid(0x7DC9D5F9, 0x9ED9, 0x44ec, 0x9B, 0xBF, 0x06, 0x00, 0xBB, 0x58, 0x9F, 0xBB)

ALL_STREAMS, FIRST_AUDIO, FIRST_VIDEO = 0xfffffffe, 0xfffffffd, 0xfffffffc
READERF_ENDOFSTREAM = 0x2
MF_VERSION = 0x0002 << 16 | 0x0070
VT_I8 = 20

_P, _G, _U32, _U64 = C.c_void_p, C.POINTER(GUID), C.c_uint32, C.c_uint64
_started = False


def _start():
    global _started
    if not _started:
        C.windll.ole32.CoInitializeEx(None, 0)  # multithreaded; it may already be initialized
        _check(C.windll.mfplat.MFStartup(MF_VERSION, 0), 'MFStartup')
        _started = True


def _check(hr, what):
    if hr < 0:
        raise OSError(f'{what} failed: 0x{hr & 0xffffffff:08x}')


def _com(obj, index, argtypes, *args, what='COM call'):
    """Calls method index of the vtable of obj."""
    vtbl = C.cast(obj, C.POINTER(C.POINTER(C.c_void_p))).contents
    hr = C.WINFUNCTYPE(C.c_long, _P, *argtypes)(vtbl[index])(obj, *args)
    _check(hr, what)


def _release(obj):
    if obj and obj.value:
        vtbl = C.cast(obj, C.POINTER(C.POINTER(C.c_void_p))).contents
        C.WINFUNCTYPE(C.c_ulong, _P)(vtbl[2])(obj)
        obj.value = None


# IMFAttributes (also IMFMediaType and IMFSample): 8 GetUINT64, 15 GetBlob, 21 SetUINT32, 24 SetGUID.
def _get_u64(attrs, key):
    v = _U64()
    _com(attrs, 8, [_G, C.POINTER(_U64)], C.byref(key), C.byref(v), what='GetUINT64')
    return v.value


def _get_u32(attrs, key):
    v = _U32()
    _com(attrs, 7, [_G, C.POINTER(_U32)], C.byref(key), C.byref(v), what='GetUINT32')
    return v.value


def _get_blob(attrs, key, size):
    buf, got = (C.c_ubyte * size)(), _U32()
    _com(attrs, 15, [_G, C.c_void_p, _U32, C.POINTER(_U32)], C.byref(key), buf, size, C.byref(got), what='GetBlob')
    return bytes(buf[:got.value])


def _set_u32(attrs, key, v):
    _com(attrs, 21, [_G, _U32], C.byref(key), v, what='SetUINT32')


def _set_guid(attrs, key, v):
    _com(attrs, 24, [_G, _G], C.byref(key), C.byref(v), what='SetGUID')


class _Reader:
    """IMFSourceReader on one stream (3 GetStreamSelection, 4 SetStreamSelection, 6 GetCurrentMediaType,
    7 SetCurrentMediaType, 8 SetCurrentPosition, 9 ReadSample)."""

    def __init__(self, url, stream):
        _start()
        self.stream = stream
        attrs, self.r = _P(), _P()
        _check(C.windll.mfplat.MFCreateAttributes(C.byref(attrs), 1), 'MFCreateAttributes')
        try:
            _set_u32(attrs, MF_SOURCE_READER_ENABLE_VIDEO_PROCESSING, 1)  # YUV to RGB32 in the reader
            fn = C.windll.mfreadwrite.MFCreateSourceReaderFromURL
            fn.argtypes = [C.c_wchar_p, _P, C.POINTER(_P)]
            _check(fn(url, attrs, C.byref(self.r)), f'opening {url[:80]}')
        finally:
            _release(attrs)
        _com(self.r, 4, [C.c_uint32, C.c_int], ALL_STREAMS, 0, what='SetStreamSelection')
        _com(self.r, 4, [C.c_uint32, C.c_int], stream, 1, what='SetStreamSelection')

    def set_type(self, major, subtype, values=()):
        mt = _P()
        _check(C.windll.mfplat.MFCreateMediaType(C.byref(mt)), 'MFCreateMediaType')
        try:
            _set_guid(mt, MF_MT_MAJOR_TYPE, major)
            _set_guid(mt, MF_MT_SUBTYPE, subtype)
            for key, v in values:
                _set_u32(mt, key, v)
            _com(self.r, 7, [C.c_uint32, C.c_void_p, _P], self.stream, None, mt, what='SetCurrentMediaType')
        finally:
            _release(mt)

    def current_type(self):
        mt = _P()
        _com(self.r, 6, [C.c_uint32, C.POINTER(_P)], self.stream, C.byref(mt), what='GetCurrentMediaType')
        return mt

    def seek(self, seconds):
        """To the key frame before seconds; where Windows refuses (a track longer than the movie), it reads
        from the start and the caller skips what comes before."""
        pos = PROPVARIANT(vt=VT_I8, value=int(round(seconds * 1e7)))
        try:
            _com(self.r, 8, [_G, C.POINTER(PROPVARIANT)], C.byref(GUID_NULL), C.byref(pos), what='SetCurrentPosition')
        except OSError:
            pass

    def read(self):
        """(time in seconds, IMFSample) of the next sample; None at the end. The sample is the caller's to release."""
        while True:
            actual, flags, ts, sample = C.c_uint32(), C.c_uint32(), C.c_longlong(), _P()
            _com(self.r, 9, [C.c_uint32, C.c_uint32, C.POINTER(C.c_uint32), C.POINTER(C.c_uint32),
                             C.POINTER(C.c_longlong), C.POINTER(_P)],
                 self.stream, 0, C.byref(actual), C.byref(flags), C.byref(ts), C.byref(sample), what='ReadSample')
            if flags.value & READERF_ENDOFSTREAM:
                _release(sample)
                return None
            if sample.value:
                return ts.value / 1e7, sample

    def close(self):
        _release(self.r)


def _sample_bytes(sample):
    """The bytes of a sample (40 GetBufferByIndex... 41 ConvertToContiguousBuffer; buffer 3 Lock, 4 Unlock)."""
    buf, ptr, length = _P(), C.c_void_p(), C.c_uint32()
    _com(sample, 41, [C.POINTER(_P)], C.byref(buf), what='ConvertToContiguousBuffer')
    try:
        _com(buf, 3, [C.POINTER(C.c_void_p), C.c_void_p, C.POINTER(C.c_uint32)], C.byref(ptr), None, C.byref(length), what='Lock')
        data = C.string_at(ptr, length.value)
        _com(buf, 4, [], what='Unlock')
        return data
    finally:
        _release(buf)


def _frame(sample, width, height, stride):
    """The RGB32 pixels of a video sample as (bytes, pitch, orientation) for Image.frombuffer."""
    buf, b2 = _P(), _P()
    _com(sample, 40, [_U32, C.POINTER(_P)], 0, C.byref(buf), what='GetBufferByIndex')
    try:
        try:
            _com(buf, 0, [_G, C.POINTER(_P)], C.byref(IID_IMF2DBuffer), C.byref(b2), what='QueryInterface')
        except OSError:
            b2 = None
        if b2:  # IMF2DBuffer: 3 Lock2D, 4 Unlock2D; scanline 0 is the top row, pitch negative if bottom-up
            scan0, pitch = C.c_void_p(), C.c_long()
            _com(b2, 3, [C.POINTER(C.c_void_p), C.POINTER(C.c_long)], C.byref(scan0), C.byref(pitch), what='Lock2D')
            try:
                p = pitch.value
                lowest = scan0.value + (p * (height - 1) if p < 0 else 0)
                data = C.string_at(lowest, abs(p) * height)
            finally:
                _com(b2, 4, [], what='Unlock2D')
                _release(b2)
            return data, abs(p), -1 if p < 0 else 1
    finally:
        _release(buf)
    data = _sample_bytes(sample)
    if stride < 0:
        return data, -stride, -1
    return data, stride, 1


def _fetch(url, offset, size, headers):
    """size bytes of url (a path or an http(s) URL) from offset; fewer at the end."""
    if not url.lower().startswith(('http://', 'https://')):
        with open(url, 'rb') as f:
            f.seek(offset)
            return f.read(size)
    import urllib.request
    request = urllib.request.Request(url, headers={**headers, 'Range': f'bytes={offset}-{offset + size - 1}'})
    with urllib.request.urlopen(request, timeout=30) as response:
        return response.read(size)


def _boxes(data, at=0, end=None):
    """(type, payload start, payload end) of the MP4 boxes in data[at:end]."""
    end = len(data) if end is None else end
    while at + 8 <= end:
        size, kind = struct.unpack('>I4s', data[at:at + 8])
        head = 8
        if size == 1:
            size, head = struct.unpack('>Q', data[at + 8:at + 16])[0], 16
        elif size == 0:
            size = end - at
        if size < head:
            return
        yield kind.decode('latin-1'), at + head, min(at + size, end)
        at += size


def _box(kind, payload):
    return struct.pack('>I4s', 8 + len(payload), kind.encode('latin-1')) + payload


def _full(kind, version, flags, payload):
    return _box(kind, struct.pack('>I', version << 24 | flags) + payload)


def _defragment(init, body, body_at):
    """A plain MP4 (one moov with the sample table, one mdat) from the header of a fragmented one with a single
    track (init, its ftyp and moov) and some of its fragments (body, which starts at byte body_at of the file).
    The source reader does not read the fragmented MP4 of YouTube; this one it reads and seeks. The track keeps
    its times: an empty edit stands for the part before the first fragment."""
    moov = next((s, e) for n, s, e in _boxes(init) if n == 'moov')
    tkhd = mdhd = hdlr = stsd = None
    minf_rest, trex, media_time = [], (0, 0, 0), 0
    for n, s, e in _boxes(init, *moov):
        if n == 'trak':
            for n2, s2, e2 in _boxes(init, s, e):
                if n2 == 'tkhd':
                    tkhd = bytearray(init[s2 - 8:e2])
                elif n2 == 'edts':
                    for n3, s3, e3 in _boxes(init, s2, e2):
                        if n3 == 'elst':
                            v1, count = init[s3] == 1, struct.unpack('>I', init[s3 + 4:s3 + 8])[0]
                            p = s3 + 8
                            for _ in range(count):
                                d, m = struct.unpack('>Qq' if v1 else '>Ii', init[p:p + (16 if v1 else 8)])
                                p += 20 if v1 else 12
                                if m != -1:
                                    media_time = m
                                    break
                elif n2 == 'mdia':
                    for n3, s3, e3 in _boxes(init, s2, e2):
                        if n3 == 'mdhd':
                            mdhd = bytearray(init[s3 - 8:e3])
                        elif n3 == 'hdlr':
                            hdlr = init[s3 - 8:e3]
                        elif n3 == 'minf':
                            for n4, s4, e4 in _boxes(init, s3, e3):
                                if n4 == 'stbl':
                                    stsd = next(init[s5 - 8:e5] for n5, s5, e5 in _boxes(init, s4, e4) if n5 == 'stsd')
                                else:
                                    minf_rest.append(init[s4 - 8:e4])
        elif n == 'mvex':
            for n2, s2, e2 in _boxes(init, s, e):
                if n2 == 'trex':  # track id, description index, then default duration, size and flags
                    trex = struct.unpack('>III', init[s2 + 12:s2 + 24])
    scale = struct.unpack('>I', mdhd[8 + (20 if mdhd[8] == 1 else 12):][:4])[0]

    samples = []  # (duration, size, flags, composition offset, start in body)
    first_time = None
    for n, s, e in _boxes(body):
        if n != 'moof':
            continue
        moof_at = s - 8
        for n2, s2, e2 in _boxes(body, s, e):
            if n2 != 'traf':
                continue
            base, d_dur, d_size, d_flags, cursor = moof_at, trex[0], trex[1], trex[2], None
            for n3, s3, e3 in _boxes(body, s2, e2):
                flags = struct.unpack('>I', body[s3:s3 + 4])[0] & 0xffffff
                p = s3 + 4
                if n3 == 'tfhd':
                    p += 4  # track id
                    if flags & 0x1:
                        base = struct.unpack('>Q', body[p:p + 8])[0] - body_at; p += 8
                    if flags & 0x2:
                        p += 4
                    if flags & 0x8:
                        d_dur = struct.unpack('>I', body[p:p + 4])[0]; p += 4
                    if flags & 0x10:
                        d_size = struct.unpack('>I', body[p:p + 4])[0]; p += 4
                    if flags & 0x20:
                        d_flags = struct.unpack('>I', body[p:p + 4])[0]; p += 4
                elif n3 == 'tfdt':
                    t = struct.unpack('>Q' if body[s3] == 1 else '>I', body[p:p + (8 if body[s3] == 1 else 4)])[0]
                    if first_time is None:
                        first_time = t
                elif n3 == 'trun':
                    signed = body[s3] == 1
                    count = struct.unpack('>I', body[p:p + 4])[0]; p += 4
                    if flags & 0x1:
                        cursor = base + struct.unpack('>i', body[p:p + 4])[0]; p += 4
                    elif cursor is None:
                        cursor = base
                    first_flags = None
                    if flags & 0x4:
                        first_flags = struct.unpack('>I', body[p:p + 4])[0]; p += 4
                    for k in range(count):
                        dur, size, sflags, cto = d_dur, d_size, d_flags, 0
                        if flags & 0x100:
                            dur = struct.unpack('>I', body[p:p + 4])[0]; p += 4
                        if flags & 0x200:
                            size = struct.unpack('>I', body[p:p + 4])[0]; p += 4
                        if flags & 0x400:
                            sflags = struct.unpack('>I', body[p:p + 4])[0]; p += 4
                        elif k == 0 and first_flags is not None:
                            sflags = first_flags
                        if flags & 0x800:
                            cto = struct.unpack('>i' if signed else '>I', body[p:p + 4])[0]; p += 4
                        samples.append((dur, size, sflags, cto, cursor))
                        cursor += size
    if not samples:
        raise ValueError('no samples in the fragments')
    first_time = first_time or 0

    def runs(values):
        out = []
        for v in values:
            if out and out[-1][1] == v:
                out[-1][0] += 1
            else:
                out.append([1, v])
        return out

    total = sum(s[0] for s in samples)
    stts = runs([s[0] for s in samples])
    ctts = runs([s[3] for s in samples])
    sync = [i + 1 for i, s in enumerate(samples) if not s[2] & 0x10000]
    data = b''.join(body[s[4]:s[4] + s[1]] for s in samples)

    def moov_box(chunk_at):
        table = [stsd,
                 _full('stts', 0, 0, struct.pack('>I', len(stts)) + b''.join(struct.pack('>II', c, v) for c, v in stts))]
        if any(v for c, v in ctts):
            table.append(_full('ctts', 1 if any(v < 0 for c, v in ctts) else 0, 0,
                               struct.pack('>I', len(ctts)) + b''.join(struct.pack('>Ii' if v < 0 else '>II', c, v) for c, v in ctts)))
        if len(sync) < len(samples):
            table.append(_full('stss', 0, 0, struct.pack('>I', len(sync)) + b''.join(struct.pack('>I', i) for i in sync)))
        table += [_full('stsc', 0, 0, struct.pack('>IIII', 1, 1, len(samples), 1)),
                  _full('stsz', 0, 0, struct.pack('>II', 0, len(samples)) + b''.join(struct.pack('>I', s[1]) for s in samples)),
                  _full('co64', 0, 0, struct.pack('>IQ', 1, chunk_at))]
        empty = max(0, first_time - media_time)  # presentation starts media_time into the original track
        edits = ([struct.pack('>Iihh', empty, -1, 1, 0)] if empty else []) + \
                [struct.pack('>Iihh', total, max(0, media_time - first_time), 1, 0)]
        movie_duration = empty + total
        th, md = bytearray(tkhd), bytearray(mdhd)
        if th[8] == 1:
            th[8 + 28:8 + 36] = struct.pack('>Q', movie_duration)
        else:
            th[8 + 20:8 + 24] = struct.pack('>I', movie_duration)
        if md[8] == 1:
            md[8 + 24:8 + 32] = struct.pack('>Q', total)
        else:
            md[8 + 16:8 + 20] = struct.pack('>I', total)
        matrix = struct.pack('>9I', 0x10000, 0, 0, 0, 0x10000, 0, 0, 0, 0x40000000)
        mvhd = _full('mvhd', 0, 0, struct.pack('>IIIIIH', 0, 0, scale, movie_duration, 0x10000, 0x100)
                     + bytes(10) + matrix + bytes(24) + struct.pack('>I', 2))
        trak = _box('trak', bytes(th) + _box('edts', _full('elst', 0, 0, struct.pack('>I', len(edits)) + b''.join(edits)))
                    + _box('mdia', bytes(md) + hdlr + _box('minf', b''.join(minf_rest) + _box('stbl', b''.join(table)))))
        return _box('moov', mvhd + trak)

    ftyp = _box('ftyp', b'isom' + struct.pack('>I', 512) + b'isomiso2avc1mp41')
    size = len(moov_box(0))  # the same size whatever the offset (co64)
    return ftyp + moov_box(len(ftyp) + size + 16) + struct.pack('>I4sQ', 1, b'mdat', 16 + len(data)) + data


def dash_section(url, start, end, path, headers=None):
    """For a fragmented MP4 with a segment index (the DASH streams of YouTube, which the source reader does
    not read over http), writes to path its header and only the segments that cover [start, end], and returns
    path; keeps a path already written. None when url is not one: the reader opens it as it is."""
    if os.path.isfile(path):
        return path
    if not url.lower().startswith(('http://', 'https://')):
        return None
    headers = headers or {}
    try:
        head = _fetch(url, 0, 1 << 16, headers)
        init_end, sidx = None, None
        for name, s, e in _boxes(head):
            if name == 'moov':
                init_end = e
            elif name == 'sidx':
                sidx = (s, e)
                break
        if init_end is None or sidx is None or sidx[1] > len(head):
            return None
        s, e = sidx
        version = head[s]
        # sidx: version and flags, reference id, timescale, earliest time and first offset (32 or 64 bits),
        # 16 reserved bits and the reference count, then 12 bytes a segment.
        if version == 0:
            scale, earliest, first = struct.unpack('>III', head[s + 8:s + 20])
            p = s + 20
        else:
            scale, earliest, first = struct.unpack('>IQQ', head[s + 8:s + 28])
            p = s + 28
        count = struct.unpack('>H', head[p + 2:p + 4])[0]
        p += 4
        offset, t, chosen = e + first, earliest / scale, []
        for _ in range(count):
            size, duration = struct.unpack('>II', head[p:p + 8])
            size &= 0x7fffffff
            seconds = duration / scale
            if t + seconds > start - 0.5 and t < end + 0.5:  # a little margin for the edit list and B-frames
                chosen.append((offset, size))
            offset += size
            t += seconds
            p += 12
        if not chosen:
            return None
        lo, hi = chosen[0][0], chosen[-1][0] + chosen[-1][1]
        body = _fetch(url, lo, hi - lo, headers)
        os.makedirs(os.path.dirname(path) or '.', exist_ok=True)
        with open(path + '.part', 'wb') as f:
            f.write(_defragment(head[:init_end], body, lo))
        os.replace(path + '.part', path)
        return path
    except (OSError, struct.error, ValueError):
        return None


def edit_offset(url, kind, headers=None):
    """Seconds to subtract from the times of Media Foundation, which ignores the edit list of an MP4 (the
    B-frame delay of the encoder, the priming of AAC or the start of a cut copied without re-encoding), for
    the first track of kind 'vide' or 'soun'. 0 when there is no edit list or the file is not an MP4."""
    headers = headers or {}
    try:
        at, moov = 0, None
        for _ in range(64):  # top-level boxes: moov is usually first, but may come after the media data
            head = _fetch(url, at, 16, headers)
            if len(head) < 8:
                break
            size, name = struct.unpack('>I4s', head[:8])
            if size == 1:
                size = struct.unpack('>Q', head[8:16])[0]
            if name == b'moov':
                moov = _fetch(url, at, size, headers)
                break
            if size < 8:
                break
            at += size
        if moov is None:
            return 0.0
        movie_scale = 1000
        for name, s, e in _boxes(moov, 8):
            if name == 'mvhd':
                movie_scale = struct.unpack('>I', moov[s + (20 if moov[s] == 1 else 12):][:4])[0] or 1000
        for name, s, e in _boxes(moov, 8):
            if name != 'trak':
                continue
            handler, scale, edits = None, None, []
            for n2, s2, e2 in _boxes(moov, s, e):
                if n2 == 'mdia':
                    for n3, s3, e3 in _boxes(moov, s2, e2):
                        if n3 == 'hdlr':
                            handler = moov[s3 + 8:s3 + 12].decode('latin-1')
                        elif n3 == 'mdhd':
                            scale = struct.unpack('>I', moov[s3 + (20 if moov[s3] == 1 else 12):][:4])[0]
                elif n2 == 'edts':
                    for n3, s3, e3 in _boxes(moov, s2, e2):
                        if n3 == 'elst':
                            v1, count = moov[s3] == 1, struct.unpack('>I', moov[s3 + 4:s3 + 8])[0]
                            p = s3 + 8
                            for _ in range(count):
                                if v1:
                                    edits.append(struct.unpack('>Qq', moov[p:p + 16])); p += 20
                                else:
                                    edits.append(struct.unpack('>Ii', moov[p:p + 8])); p += 12
            if handler != kind:
                continue
            delay = 0.0
            for duration, media_time in edits:
                if media_time == -1:  # an empty edit: the track starts later
                    delay += duration / movie_scale
                    continue
                return media_time / (scale or 1) - delay
            return -delay
    except (OSError, struct.error, ValueError):
        pass
    return 0.0


def decode_frames(url, start, end, fps, offset=0.0):
    """Yields (t, PIL image) for t = start + i/fps before end: the frame shown at t (the last one starting by t).
    offset is edit_offset(url, 'vide')."""
    count = max(1, round((end - start) * fps))
    times = [start + i / fps for i in range(count)]
    r = _Reader(url, FIRST_VIDEO)
    try:
        r.set_type(MFMediaType_Video, MFVideoFormat_RGB32)
        mt = r.current_type()
        try:
            size = _get_u64(mt, MF_MT_FRAME_SIZE)
            width, height = size >> 32, size & 0xffffffff
            try:
                stride = struct.unpack('<i', struct.pack('<I', _get_u32(mt, MF_MT_DEFAULT_STRIDE)))[0]
            except OSError:
                stride = width * 4
            try:  # MFVideoArea: the decoder may give 1088 lines of which 1080 are shown
                fx, ox, fy, oy, cx, cy = struct.unpack('<HhHhii', _get_blob(mt, MF_MT_MINIMUM_DISPLAY_APERTURE, 16))
                crop = (ox, oy, ox + cx, oy + cy) if cx > 0 and cy > 0 else None
            except OSError:
                crop = None
        finally:
            _release(mt)

        def image(f):
            data, pitch, orientation = f
            im = Image.frombuffer('RGB', (width, height), data, 'raw', 'BGRX', pitch, orientation)
            return im.crop(crop) if crop and crop != (0, 0, width, height) else im.copy()

        r.seek(max(0.0, start + offset))
        shown, i = None, 0  # the sample on screen, kept without copying its pixels until a time needs them
        try:
            while i < count:
                got = r.read()
                if got is None:
                    break
                t, sample = got
                t -= offset
                if t > times[i] + 1e-4 and shown is not None:  # this frame starts after times[i]: shown is the one at times[i]
                    im = image(_frame(shown, width, height, stride))
                    while i < count and t > times[i] + 1e-4:
                        yield times[i], im
                        i += 1
                _release(shown)
                shown = sample
            if shown is not None and i < count:
                im = image(_frame(shown, width, height, stride))
                for k in range(i, count):  # the stream ended: the last frame stays on screen
                    yield times[k], im
        finally:
            _release(shown)
    finally:
        r.close()


def decode_audio(url, start, end, rate=48000, offset=0.0):
    """(mono float samples between start and end, rate), resampled by Windows. offset is edit_offset(url, 'soun')."""
    r = _Reader(url, FIRST_AUDIO)
    try:
        r.set_type(MFMediaType_Audio, MFAudioFormat_Float, [
            (MF_MT_AUDIO_NUM_CHANNELS, 1), (MF_MT_AUDIO_SAMPLES_PER_SECOND, rate), (MF_MT_AUDIO_BITS_PER_SAMPLE, 32),
            (MF_MT_AUDIO_BLOCK_ALIGNMENT, 4), (MF_MT_AUDIO_AVG_BYTES_PER_SECOND, rate * 4)])
        r.seek(max(0.0, start + offset))
        chunks, first = [], None
        while True:
            got = r.read()
            if got is None:
                break
            t, sample = got
            t -= offset
            try:
                if first is None:
                    first = t
                if t >= end:
                    break
                chunks.append(_sample_bytes(sample))
            finally:
                _release(sample)
        data = b''.join(chunks)
        if first is None:
            return [], rate
        n = max(0, round((end - start) * rate))
        samples = list(struct.unpack(f'<{len(data) // 4}f', data))
        lead = round((first - start) * rate)
        if lead > 0:  # the sound starts after start: silence before it
            samples = [0.0] * lead + samples
        else:
            samples = samples[-lead:]
        return samples[:n] + [0.0] * max(0, n - len(samples)), rate
    finally:
        r.close()


def resolve(source, item=1):
    """(name, video url, audio url, http headers) of source; a local file is both streams."""
    if os.path.isfile(source):
        return os.path.basename(source).rsplit('.', 1)[0], source, source, {}
    import yt_dlp
    # Windows decodes H.264 and AAC without extensions; one URL per stream (no HLS or DASH segments).
    # res is the short side, so a vertical 720x1280 video (X, Shorts) counts as 720p and is not skipped.
    fmt = ('bv*[vcodec^=avc1][protocol=https]+ba[acodec^=mp4a][protocol=https]'
           '/b[vcodec^=avc1][protocol=https]/b[ext=mp4][protocol=https]')
    with yt_dlp.YoutubeDL({'quiet': True, 'format': fmt, 'format_sort': ['res:1080']}) as ydl:
        info = ydl.extract_info(source, download=False)
    entries = [e for e in (info.get('entries') or []) if e]
    if entries:  # a post with several videos
        info = entries[min(item, len(entries)) - 1]
    streams = info.get('requested_formats') or [info]
    video = next((s for s in streams if s.get('vcodec') != 'none'), streams[0])
    sound = next((s for s in streams if s.get('acodec') != 'none'), streams[-1])
    return info['id'], video['url'], sound['url'], video.get('http_headers') or {}


def frames(url, headers, start, end, fps, out, width):
    """[(t, png path, thumbnail width wide)]; the PNGs are written on threads (Pillow releases the GIL)."""
    from concurrent.futures import ThreadPoolExecutor
    folder = os.path.join(out, 'frames')
    os.makedirs(folder, exist_ok=True)
    for f in os.listdir(folder):
        os.remove(os.path.join(folder, f))
    result, pending = [], []
    with ThreadPoolExecutor(os.cpu_count() or 4) as pool:
        for t, image in decode_frames(url, start, end, fps, edit_offset(url, 'vide', headers)):
            path = os.path.join(folder, f'{t:08.3f}.png')
            pending.append(pool.submit(image.save, path, compress_level=1))
            height = round(width * image.height / image.width)
            result.append((t, path, image.resize((width, height), Image.LANCZOS, reducing_gap=3.0)))
        for p in pending:
            p.result()
    return result


def strip(frames, columns, width, out):
    if not frames:
        return None
    height = frames[0][2].height
    rows = (len(frames) + columns - 1) // columns
    sheet = Image.new('RGB', (columns * width, rows * height), (0, 0, 0))
    draw = ImageDraw.Draw(sheet)
    try:
        font = ImageFont.truetype('arialbd.ttf', max(14, height // 12))
    except OSError:
        font = ImageFont.load_default()
    for i, (t, path, thumbnail) in enumerate(frames):
        x, y = (i % columns) * width, (i // columns) * height
        sheet.paste(thumbnail, (x, y))
        label = f'{t:.2f}s'
        box = draw.textbbox((x + 4, y + 2), label, font=font)
        draw.rectangle((box[0] - 3, box[1] - 2, box[2] + 3, box[3] + 2), fill=(0, 0, 0))
        draw.text((x + 4, y + 2), label, fill=(255, 255, 255), font=font)
    path = os.path.join(out, 'strip.png')
    sheet.save(path)
    return path


def audio(url, headers, start, end, out):
    samples, rate = decode_audio(url, start, end, offset=edit_offset(url, 'soun', headers))
    path = os.path.join(out, 'audio.wav')
    with wave.open(path, 'wb') as w:  # 16-bit PCM
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(rate)
        w.writeframes(struct.pack(f'<{len(samples)}h', *(max(-32768, min(32767, round(s * 32767))) for s in samples)))
    return path


def main():
    if sys.platform != 'win32':
        sys.exit('video_frames needs Windows: it decodes with Media Foundation')
    a = argparse.ArgumentParser()
    a.add_argument('source')
    a.add_argument('--start', type=float, required=True)
    a.add_argument('--end', type=float, required=True)
    a.add_argument('--fps', type=float)
    a.add_argument('--every', type=float, help='seconds between frames (instead of --fps)')
    a.add_argument('--columns', type=int, default=6)
    a.add_argument('--width', type=int, default=480)
    a.add_argument('--out')
    a.add_argument('--audio', action='store_true')
    a.add_argument('--item', type=int, default=1, help='which video of a post with several (1 is the first)')
    args = a.parse_args()
    fps = args.fps or (1 / args.every if args.every else 10)
    name, video, sound, headers = resolve(args.source, args.item)
    slug = re.sub(r'[^A-Za-z0-9]+', '_', name)
    out = args.out or os.path.join(WORK, 'out', f'{slug}_{args.start:g}-{args.end:g}_{fps:g}fps')
    os.makedirs(out, exist_ok=True)
    # The DASH streams of YouTube: only their segments of the section, kept in cache/ by video id.
    cache = os.path.join(WORK, 'cache', f'{slug}_{args.start:g}-{args.end:g}')
    video = dash_section(video, args.start, args.end, cache + '_video.mp4', headers) or video
    if args.audio:
        sound = dash_section(sound, args.start, args.end, cache + '_audio.mp4', headers) or sound
    shots = frames(video, headers, args.start, args.end, fps, out, args.width)
    if not shots:
        sys.exit(f'no frames between {args.start:g} and {args.end:g}: is the section past the end of the video?')
    result = {'source': args.source, 'frames': len(shots), 'folder': os.path.join(out, 'frames'),
              'strip': strip(shots, args.columns, args.width, out)}
    if args.audio:
        result['audio'] = audio(sound, headers, args.start, args.end, out)
    print(json.dumps(result, indent=1))


if __name__ == '__main__':
    main()
