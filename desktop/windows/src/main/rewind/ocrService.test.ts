import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { mkdtemp, mkdir, open, rm, symlink, writeFile } from 'fs/promises'
import { tmpdir } from 'os'
import { join } from 'path'
import { MAX_REWIND_FRAME_BYTES } from './frameFile'

const state = vi.hoisted(() => ({
  root: '',
  frames: [] as Array<{ id: number; imagePath: string }>,
  ocr: vi.fn(),
  setOcr: vi.fn()
}))

vi.mock('../ocr/helperProcess', () => ({
  helperProcess: { ocr: (jpeg: Buffer) => state.ocr(jpeg) }
}))
vi.mock('../ipc/db', () => ({
  unindexedRewindFrames: () => state.frames,
  setRewindFrameOcr: (...args: unknown[]) => state.setOcr(...args)
}))
vi.mock('./paths', () => ({ rewindRoot: () => state.root }))

import { backfillRewindOcr } from './ocrService'

describe('Rewind OCR backfill boundary', () => {
  const tempPaths: string[] = []

  beforeEach(() => {
    state.frames = []
    state.ocr.mockReset()
    state.setOcr.mockReset()
  })

  afterEach(async () => {
    await Promise.all(tempPaths.splice(0).map((path) => rm(path, { recursive: true, force: true })))
  })

  async function frameRoot(): Promise<string> {
    const temp = await mkdtemp(join(tmpdir(), 'omi-rewind-ocr-'))
    tempPaths.push(temp)
    const root = join(temp, 'rewind')
    await mkdir(root)
    state.root = root
    return root
  }

  it('OCRs a valid persisted frame', async () => {
    const root = await frameRoot()
    const frame = join(root, '1.jpg')
    await writeFile(frame, Buffer.from('jpeg'))
    state.frames = [{ id: 1, imagePath: frame }]
    state.ocr.mockResolvedValue({ ok: true, fullText: 'text' })

    await backfillRewindOcr()

    expect(state.ocr).toHaveBeenCalledWith(Buffer.from('jpeg'))
    expect(state.setOcr).toHaveBeenCalledWith(1, 'text')
  })

  it('does not OCR a frame that escapes through a reparse link', async () => {
    const root = await frameRoot()
    const outside = join(root, '..', 'outside')
    const linked = join(root, 'linked')
    await mkdir(outside)
    await writeFile(join(outside, '1.jpg'), Buffer.from('jpeg'))
    await symlink(outside, linked, process.platform === 'win32' ? 'junction' : 'dir')
    state.frames = [{ id: 2, imagePath: join(linked, '1.jpg') }]

    await backfillRewindOcr()

    expect(state.ocr).not.toHaveBeenCalled()
    expect(state.setOcr).toHaveBeenCalledWith(2, '')
  })

  it('does not OCR an oversized persisted frame', async () => {
    const root = await frameRoot()
    const frame = join(root, 'large.jpg')
    const handle = await open(frame, 'w')
    await handle.truncate(MAX_REWIND_FRAME_BYTES + 1)
    await handle.close()
    state.frames = [{ id: 3, imagePath: frame }]

    await backfillRewindOcr()

    expect(state.ocr).not.toHaveBeenCalled()
    expect(state.setOcr).toHaveBeenCalledWith(3, '')
  })
})
