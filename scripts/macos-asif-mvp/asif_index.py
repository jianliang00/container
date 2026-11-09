"""Read candidate logical blocks from the observed ASIF v1 layout.

Payload, overlay resolution and all writes remain the native image driver's job.
Layout notes: https://github.com/huven/asif-format
"""

import os
import struct

from image import regular, require

BLOCK = 1 << 20
SECTOR = 512
ENTRIES = 4 * SECTOR
GROUP_BYTES = 8 * (ENTRIES + 1)
GROUPS = BLOCK // GROUP_BYTES
TABLE_BLOCKS = GROUPS * ENTRIES
PHYSICAL_MASK = (1 << 55) - 1
RESERVED_MASK = ((1 << 62) - 1) ^ PHYSICAL_MASK


class UnsupportedLayout(Exception):
    """The native full scan may handle layouts this reader does not know."""


def ceil_div(value, divisor):
    return (value + divisor - 1) // divisor


def candidates(path, logical_size):
    """Include whole chunks for every data, partial or unmap entry."""
    with regular(path).open('rb', buffering=0) as stream:
        length = os.fstat(stream.fileno()).st_size

        def read(offset, count):
            require(0 <= offset <= length - count, 'ASIF index points outside file')
            data = os.pread(stream.fileno(), count, offset)
            require(len(data) == count, 'short ASIF index read')
            return data

        if length < 8 or read(0, 8) != b'shdw\x00\x00\x00\x01':
            raise UnsupportedLayout('unrecognized ASIF header')
        header = read(0, SECTOR)
        header_size, flags, first, second = struct.unpack_from('>IIQQ', header, 8)
        sectors, maximum, chunk, sector, segments = struct.unpack_from('>QQIHH', header, 48)
        if (header_size, flags, chunk, sector, segments) != (SECTOR, 0, BLOCK, SECTOR, 0):
            raise UnsupportedLayout('unsupported ASIF v1 geometry or flags')
        require(0 < sectors <= maximum, 'invalid ASIF sector count')
        if sectors * SECTOR != logical_size:
            raise UnsupportedLayout('overlay logical size differs from base')
        dir_bytes = 8 * (1 + ceil_div(maximum * SECTOR, TABLE_BLOCKS * BLOCK))
        require(SECTOR <= first and first % SECTOR == second % SECTOR == 0
                and first + dir_bytes <= second and second + dir_bytes <= BLOCK,
                'invalid ASIF directory bounds')
        directories = [read(first, dir_bytes), read(second, dir_bytes)]
        # Sequence numbers are big endian and occupy the first eight bytes.
        require(directories[0][:8] != directories[1][:8] or directories[0] == directories[1],
                'conflicting ASIF directory sequence')
        entries = [v for (v,) in struct.iter_unpack('>Q', max(directories))][1:]
        tables = {v for v in entries if v}
        require(len(tables) == sum(bool(v) for v in entries)
                and all(v * BLOCK <= length - BLOCK for v in tables), 'invalid ASIF table reference')

        limit = ceil_div(logical_size, BLOCK)
        result = set()
        used = {0, *tables}
        for table_index, table in enumerate(entries[:ceil_div(limit, TABLE_BLOCKS)]):
            if not table:
                continue
            data = read(table * BLOCK, BLOCK)
            for group in range(GROUPS):
                start = table_index * TABLE_BLOCKS + group * ENTRIES
                if start >= limit:
                    break
                entries_start = group * GROUP_BYTES
                bitmap = struct.unpack_from('>Q', data, entries_start + ENTRIES * 8)[0]
                if bitmap:
                    require(bitmap not in used and bitmap * BLOCK <= length - BLOCK,
                            'invalid ASIF bitmap reference')
                    used.add(bitmap)
                count = min(ENTRIES, limit - start)
                group_data = data[entries_start:entries_start + count * 8]
                for index, (entry,) in enumerate(struct.iter_unpack('>Q', group_data)):
                    if not entry:
                        continue
                    state, physical = entry >> 62, entry & PHYSICAL_MASK
                    require(not entry & RESERVED_MASK and state != 0, 'invalid ASIF chunk flags')
                    if state == 1:
                        require(physical and physical * BLOCK <= length - BLOCK, 'invalid ASIF data chunk')
                    elif state == 2:
                        require(not physical, 'invalid ASIF unmap entry')
                    else:
                        # A trim-only partial entry may have a bitmap but no payload.
                        require(bitmap and (not physical or physical * BLOCK < length), 'invalid ASIF partial entry')
                    if physical:
                        require(physical not in used, 'aliased ASIF chunk reference')
                        used.add(physical)
                    result.add((start + index) * BLOCK)
        return result
