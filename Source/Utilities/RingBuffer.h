/*++

Module Name:

    RingBuffer.h

Abstract:

    In-kernel byte ring carrying rendered audio from the "Unitra Speaker"
    render stream to the "Unitra Microphone" capture stream.

    Ported from JannesP/AudioMirror (MIT) with two donor bugs fixed on the
    way in:
      - Put() ran without the spinlock while Take()/Clear() held it.
      - Put() never advanced its source pointer across a wrap, so any
        write that straddled the end of the ring duplicated its first
        bytes instead of copying its tail.
    The donor's byte-align staging buffer (PutInternal/m_AlignBuffer) was
    recursive dead code and is dropped: WaveRT packets are frame-aligned
    by construction, and Init() rejects a misaligned ring size instead.

--*/
#pragma once

#include "definitions.h"

class RingBuffer
{
private:
    KSPIN_LOCK m_BufferLock;
    BYTE*      m_Buffer;
    SIZE_T     m_BufferLength;
    SIZE_T     m_nByteAlign;
    BOOL       m_IsFilling;

    ULONGLONG  m_LinearReadPosition;
    ULONGLONG  m_LinearWritePosition;

public:
    RingBuffer();
    ~RingBuffer();

    NTSTATUS Init(_In_ SIZE_T bufferSize, _In_ SIZE_T nByteAlign);

    // Copies count bytes into the ring. On overrun the read position is
    // advanced (frame-aligned) and STATUS_BUFFER_OVERFLOW is returned -
    // the newest audio wins, which is the right policy for a live mic.
    NTSTATUS Put(_In_reads_bytes_(count) BYTE* pBytes, _In_ SIZE_T count);

    // Copies up to count bytes out. While the ring is refilling after an
    // underrun it reports STATUS_DEVICE_NOT_READY with *readCount = 0 and
    // the caller zero-fills - half-full priming avoids a tight
    // starve/burst cycle at stream start.
    NTSTATUS Take(
        _Out_writes_bytes_to_(count, *readCount) BYTE* pTarget,
        _In_ SIZE_T count,
        _Out_ SIZE_T* readCount);

    SIZE_T GetSize();

    void Clear();
};
