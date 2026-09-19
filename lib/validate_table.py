"""Read saved table files only; validate geometry and manifest correspondence.

GPT fdisk backups contain a 512-byte MBR, two 512-byte headers and one
entry array (https://www.rodsbooks.com/gdisk/repairing.html). No device opens.
DOS support is deliberately restricted to primary partitions; extended tables
need separate logical-partition/EBR recovery coverage before acceptance.
"""
import json
from pathlib import Path
import re
import struct
import sys
import uuid
import zlib


def require(condition, message):
    if not condition:
        raise ValueError(message)


def header(data):
    require(len(data) == 512 and data[:8] == b'EFI PART', 'invalid GPT header')
    revision, size, crc, reserved = struct.unpack_from('<4I', data, 8)
    require(revision == 0x10000 and 92 <= size <= 512 and reserved == 0, 'unsupported GPT header')
    check = bytearray(data[:size]); check[16:20] = b'\0' * 4
    require(zlib.crc32(check) == crc, 'GPT header checksum mismatch')
    current, alternate, first, last = struct.unpack_from('<4Q', data, 24)
    entries_lba, count, width, entries_crc = struct.unpack_from('<Q3I', data, 72)
    require(0 < count <= 16384 and width == 128, 'unsupported GPT entry layout')
    return current, alternate, first, last, data[56:72], entries_lba, count, width, entries_crc


def gpt(data, capacity):
    require(len(data) >= 1536 and data[510:512] == b'\x55\xaa', 'invalid protective MBR')
    types = [data[446 + i * 16 + 4] for i in range(4)]
    require(types.count(0xEE) == 1 and all(t in (0, 0xEE) for t in types), 'hybrid/nonprotective MBR unsupported')
    a, b = header(data[512:1024]), header(data[1024:1536])
    require(a[0] == 1 and b[0] == a[1] and b[1] == 1, 'GPT header locations disagree')
    require(a[2:5] == b[2:5] and a[6:] == b[6:], 'GPT headers disagree')
    sectors = a[1] + 1
    require(capacity % sectors == 0 and capacity // sectors in (512, 4096), 'source capacity/sector geometry mismatch')
    sector = capacity // sectors
    table_sectors = (a[6] * a[7] + sector - 1) // sector
    require(a[5] == 2 and a[2] >= 2 + table_sectors and a[2] <= a[3] < b[5]
            and b[5] + table_sectors == b[0], 'invalid GPT usable range')
    entries = data[1536:]
    require(len(entries) == a[6] * a[7], 'GPT backup length mismatch')
    require(zlib.crc32(entries) == a[8], 'GPT partition array checksum mismatch')
    parts = {}
    for i in range(a[6]):
        entry = entries[i * 128:(i + 1) * 128]
        if entry[:16] == b'\0' * 16:
            continue
        start, end = struct.unpack_from('<2Q', entry, 32)
        require(a[2] <= start <= end <= a[3], 'GPT partition outside usable range')
        parts[i + 1] = (start, end, str(uuid.UUID(bytes_le=entry[16:32])))
    return sector, parts


def dos(data, capacity):
    text = data.decode('utf-8')
    headers, parts = {}, {}
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith('#'):
            continue
        if re.match(r'^/dev/', line):
            match = re.fullmatch(r'(/dev/[^\s:]+?)(\d+)\s*:\s*start=\s*(\d+),\s*size=\s*(\d+),\s*type=([0-9a-fA-F]+)(,\s*bootable)?', line)
            require(match is not None, 'unsupported DOS partition record')
            _, number, start, size, kind, _ = match.groups()
            number, start, size, kind = int(number), int(start), int(size), int(kind, 16)
            require(1 <= number <= 4 and number not in parts and kind not in (0, 5, 15, 0x85), 'extended/logical or invalid DOS partition unsupported')
            require(start > 0 and size > 0, 'invalid DOS partition range')
            parts[number] = (start, start + size - 1, None)
        else:
            key, sep, value = line.partition(':')
            require(sep and key not in headers and key in ('label', 'label-id', 'device', 'unit', 'sector-size'), 'unsupported DOS dump header')
            headers[key] = value.strip()
    require(headers.get('label') == 'dos' and headers.get('unit') == 'sectors', 'invalid DOS dump')
    require(re.fullmatch(r'0x[0-9a-fA-F]{8}', headers.get('label-id', '')), 'missing DOS disk identity')
    sector = int(headers.get('sector-size', '512'))
    require(sector in (512, 4096) and capacity % sector == 0, 'invalid DOS sector size')
    require(all(end < capacity // sector for _, end, _ in parts.values()), 'DOS partition outside disk')
    return sector, parts


def validate(manifest_path):
    path = Path(manifest_path)
    manifest = json.loads(path.read_text())
    table_path = path.parent / manifest['partition_table']['dump_file']
    require(table_path.is_file() and not table_path.is_symlink(), 'table must be a regular nonsymlink file')
    require(table_path.stat().st_size <= 4 * 1024 * 1024, 'table dump too large')
    data = table_path.read_bytes()
    parser = {'gpt': gpt, 'dos': dos}[manifest['partition_table']['type']]
    sector, parts = parser(data, manifest['source_disk']['size_bytes'])
    records = manifest['partitions']
    require(set(parts) == {p['number'] for p in records}, 'partition numbers differ from manifest')
    previous = -1
    for start, end, _ in sorted(parts.values()):
        require(start > previous, 'overlapping partitions')
        previous = end
    for part in records:
        start, end, identity = parts[part['number']]
        require((end - start + 1) * sector == part['size_bytes'], 'partition size differs from manifest')
        if identity is not None:
            require(part.get('partuuid', '').lower() == identity, 'partition UUID differs from manifest')
    return sector


if __name__ == '__main__':
    try:
        sector = validate(sys.argv[1])
        if len(sys.argv) > 2 and sys.argv[2] == "--sector-size":
            print(sector)
    except (ValueError, KeyError, OSError, TypeError, struct.error) as error:
        print(f'Invalid partition table: {error}', file=sys.stderr)
        sys.exit(1)
