/*++

Module Name:

    RingBuffer.cpp

Abstract:

    Render -> capture ring for the Unitra virtual audio cable. See the
    header for provenance and the two donor bugs fixed in this port.

--*/
#include "definitions.h"
#include "RingBuffer.h"

#define RING_BUFFER_TAG 'BRnU' // "UnRB"

#pragma code_seg()

RingBuffer::RingBuffer()
    : m_Buffer(NULL),
      m_BufferLength(0),
      m_nByteAlign(1),
      m_IsFilling(TRUE),
      m_LinearReadPosition(0),
      m_LinearWritePosition(0)
{
    KeInitializeSpinLock(&m_BufferLock);
}

RingBuffer::~RingBuffer()
{
    // No lock: destruction races nothing - the owning stream detaches the
    // paired stream before freeing, and both sides run at PASSIVE_LEVEL
    // teardown by then.
    if (m_Buffer != NULL)
    {
        ExFreePoolWithTag(m_Buffer, RING_BUFFER_TAG);
        m_Buffer = NULL;
        m_BufferLength = 0;
    }
}

#pragma code_seg("PAGE")
NTSTATUS RingBuffer::Init(_In_ SIZE_T bufferSize, _In_ SIZE_T nByteAlign)
{
    PAGED_CODE();

    if (bufferSize == 0 || nByteAlign == 0 || (bufferSize % nByteAlign) != 0)
    {
        // A ring whose length is not a whole number of frames would let
        // wraps split a frame between two passes and desync the channels.
        return STATUS_INVALID_PARAMETER;
    }

    BYTE* newBuffer = static_cast<BYTE*>(
        ExAllocatePool2(POOL_FLAG_NON_PAGED, bufferSize, RING_BUFFER_TAG));
    if (newBuffer == NULL)
    {
        return STATUS_INSUFFICIENT_RESOURCES;
    }

    KIRQL irql;
    KeAcquireSpinLock(&m_BufferLock, &irql);
    BYTE* oldBuffer = m_Buffer;
    m_Buffer = newBuffer;
    m_BufferLength = bufferSize;
    m_nByteAlign = nByteAlign;
    m_LinearReadPosition = 0;
    m_LinearWritePosition = 0;
    m_IsFilling = TRUE;
    KeReleaseSpinLock(&m_BufferLock, irql);

    if (oldBuffer != NULL)
    {
        ExFreePoolWithTag(oldBuffer, RING_BUFFER_TAG);
    }
    return STATUS_SUCCESS;
}

#pragma code_seg()
NTSTATUS RingBuffer::Put(_In_reads_bytes_(count) BYTE* pBytes, _In_ SIZE_T count)
{
    if (count == 0)
    {
        return STATUS_SUCCESS;
    }

    NTSTATUS status = STATUS_SUCCESS;
    KIRQL irql;
    // Donor bug #1: this ran lockless against Take()'s read-position
    // update, so a concurrent capture tick could tear the positions.
    KeAcquireSpinLock(&m_BufferLock, &irql);

    if (m_Buffer == NULL || count > m_BufferLength)
    {
        KeReleaseSpinLock(&m_BufferLock, irql);
        return m_Buffer == NULL ? STATUS_DEVICE_NOT_READY : STATUS_BUFFER_TOO_SMALL;
    }

    // Overrun: drop the oldest audio, keeping the read position on a frame
    // boundary (the donor advanced by +1, which shifted every later frame
    // read off alignment and turned 16-bit samples into noise).
    if ((m_LinearWritePosition + count) - m_LinearReadPosition > m_BufferLength)
    {
        status = STATUS_BUFFER_OVERFLOW;
        ULONGLONG minRead = (m_LinearWritePosition + count) - m_BufferLength;
        ULONGLONG misalign = minRead % m_nByteAlign;
        if (misalign != 0)
        {
            minRead += m_nByteAlign - misalign;
        }
        m_LinearReadPosition = minRead;
    }

    SIZE_T bufferOffset = (SIZE_T)(m_LinearWritePosition % m_BufferLength);
    SIZE_T bytesWritten = 0;
    while (count > 0)
    {
        SIZE_T runWrite = min(count, m_BufferLength - bufferOffset);
        // Donor bug #2: the source pointer stayed at pBytes across the
        // wrap, duplicating the head of the packet into the ring's tail.
        RtlCopyMemory(m_Buffer + bufferOffset, pBytes + bytesWritten, runWrite);
        bufferOffset = (bufferOffset + runWrite) % m_BufferLength;
        count -= runWrite;
        bytesWritten += runWrite;
    }
    m_LinearWritePosition += bytesWritten;

    if (m_IsFilling &&
        (m_LinearWritePosition - m_LinearReadPosition) > (m_BufferLength / 2))
    {
        m_IsFilling = FALSE;
    }

    KeReleaseSpinLock(&m_BufferLock, irql);
    return status;
}

#pragma code_seg()
NTSTATUS RingBuffer::Take(
    _Out_writes_bytes_to_(count, *readCount) BYTE* pTarget,
    _In_ SIZE_T count,
    _Out_ SIZE_T* readCount)
{
    KIRQL irql;
    KeAcquireSpinLock(&m_BufferLock, &irql);

    if (m_Buffer == NULL || m_IsFilling)
    {
        *readCount = 0;
        KeReleaseSpinLock(&m_BufferLock, irql);
        return STATUS_DEVICE_NOT_READY;
    }

    count = (SIZE_T)min((ULONGLONG)count, m_LinearWritePosition - m_LinearReadPosition);
    SIZE_T bufferOffset = (SIZE_T)(m_LinearReadPosition % m_BufferLength);
    SIZE_T bytesRead = 0;
    while (count > 0)
    {
        SIZE_T runRead = min(count, m_BufferLength - bufferOffset);
        RtlCopyMemory(pTarget + bytesRead, m_Buffer + bufferOffset, runRead);
        bufferOffset = (bufferOffset + runRead) % m_BufferLength;
        count -= runRead;
        bytesRead += runRead;
    }
    *readCount = bytesRead;
    m_LinearReadPosition += bytesRead;

    if (m_LinearWritePosition - m_LinearReadPosition == 0)
    {
        // Drained dry: go back to priming so the next underrun gets a
        // half-buffer cushion instead of oscillating around empty.
        m_IsFilling = TRUE;
    }

    KeReleaseSpinLock(&m_BufferLock, irql);
    return STATUS_SUCCESS;
}

#pragma code_seg()
SIZE_T RingBuffer::GetSize()
{
    return m_BufferLength;
}

#pragma code_seg()
void RingBuffer::Clear()
{
    KIRQL irql;
    KeAcquireSpinLock(&m_BufferLock, &irql);
    if (m_Buffer != NULL)
    {
        RtlZeroMemory(m_Buffer, m_BufferLength);
    }
    m_IsFilling = TRUE;
    m_LinearReadPosition = 0;
    m_LinearWritePosition = 0;
    KeReleaseSpinLock(&m_BufferLock, irql);
}
