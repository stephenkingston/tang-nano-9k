#!/usr/bin/env python3
"""AES-128 in CBC mode with PKCS#7 padding: the reference for term_aes in terminal.v, which the
built-in shell's key, iv, enc and dec commands use.

A plain byte-at-a-time implementation after FIPS-197, checked against its example vector and
the CBC vectors of NIST SP 800-38A when run on its own:

  python3 term_aes.py
"""


def _xtime(a):
    return ((a << 1) ^ (0x1B if a & 0x80 else 0)) & 0xFF


def _mul(a, b):
    r = 0
    while b:
        if b & 1:
            r ^= a
        a, b = _xtime(a), b >> 1
    return r


def _sboxes():
    inv = [0] * 256                                     # multiplicative inverses in GF(2^8)
    for a in range(1, 256):
        for b in range(1, 256):
            if _mul(a, b) == 1:
                inv[a] = b
                break
    sbox = []
    for a in range(256):
        x = inv[a]
        s = x
        for _ in range(4):                              # the affine transform
            x = ((x << 1) | (x >> 7)) & 0xFF
            s ^= x
        sbox.append(s ^ 0x63)
    isbox = [0] * 256
    for a, s in enumerate(sbox):
        isbox[s] = a
    return sbox, isbox


SBOX, INV_SBOX = _sboxes()
RCON = [0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80, 0x1B, 0x36]


def expand_key(key):
    """The 11 round keys as 176 bytes."""
    assert len(key) == 16
    w = list(key)
    for j in range(16, 176):
        if j % 16 < 4:                                  # first word of a round key
            t = SBOX[w[j - 4 - j % 4 + (j + 1) % 4]] ^ (RCON[j // 16 - 1] if j % 4 == 0 else 0)
        else:
            t = w[j - 4]
        w.append(w[j - 16] ^ t)
    return bytes(w)


def _mix(col, m):
    return [_mul(col[i], m[0]) ^ _mul(col[(i + 1) % 4], m[1]) ^ _mul(col[(i + 2) % 4], m[2]) ^
            _mul(col[(i + 3) % 4], m[3]) for i in range(4)]


def encrypt_block(rk, block):
    s = [b ^ k for b, k in zip(block, rk[:16])]
    for r in range(1, 11):
        out = []
        for c in range(4):
            col = [SBOX[s[k + 4 * ((c + k) % 4)]] for k in range(4)]         # ShiftRows, SubBytes
            out += _mix(col, (2, 3, 1, 1)) if r < 10 else col
        s = [b ^ k for b, k in zip(out, rk[16 * r:16 * r + 16])]
    return bytes(s)


def decrypt_block(rk, block):
    s = [b ^ k for b, k in zip(block, rk[160:])]
    for r in range(9, -1, -1):
        out = []
        for c in range(4):
            col = [INV_SBOX[s[k + 4 * ((c - k) % 4)]] ^ rk[16 * r + 4 * c + k] for k in range(4)]
            out += _mix(col, (14, 11, 13, 9)) if r > 0 else col
        s = out
    return bytes(s)


def pad(data):
    n = 16 - len(data) % 16
    return data + bytes([n]) * n


def unpad(data):
    """The data without its PKCS#7 padding, or None if the padding is not valid."""
    n = data[-1] if data else 0
    if not 1 <= n <= 16 or data[-n:] != bytes([n]) * n:
        return None
    return data[:-n]


def cbc_encrypt(key, iv, data):
    rk, prev, out = expand_key(key), iv, b''
    for i in range(0, len(data), 16):
        prev = encrypt_block(rk, bytes(a ^ b for a, b in zip(data[i:i + 16], prev)))
        out += prev
    return out


def cbc_decrypt(key, iv, data):
    rk, prev, out = expand_key(key), iv, b''
    for i in range(0, len(data), 16):
        block = data[i:i + 16]
        out += bytes(a ^ b for a, b in zip(decrypt_block(rk, block), prev))
        prev = block
    return out


# FIPS-197 appendix C.1, and NIST SP 800-38A F.2.1 (CBC-AES128)
FIPS_KEY = bytes(range(16))
FIPS_PT = bytes.fromhex('00112233445566778899aabbccddeeff')
FIPS_CT = bytes.fromhex('69c4e0d86a7b0430d8cdb78070b4c55a')
SP_KEY = bytes.fromhex('2b7e151628aed2a6abf7158809cf4f3c')
SP_IV = bytes.fromhex('000102030405060708090a0b0c0d0e0f')
SP_PT = bytes.fromhex('6bc1bee22e409f96e93d7e117393172a' 'ae2d8a571e03ac9c9eb76fac45af8e51'
                      '30c81c46a35ce411e5fbc1191a0a52ef' 'f69f2445df4f9b17ad2b417be66c3710')
SP_CT = bytes.fromhex('7649abac8119b246cee98e9b12e9197d' '5086cb9b507219ee95db113a917678b2'
                      '73bed6b8e3c1743b7116e69e22229516' '3ff1caa1681fac09120eca307586e1a7')


def self_test():
    rk = expand_key(FIPS_KEY)
    assert encrypt_block(rk, FIPS_PT) == FIPS_CT and decrypt_block(rk, FIPS_CT) == FIPS_PT
    assert expand_key(SP_KEY)[160:].hex() == 'd014f9a8c9ee2589e13f0cc8b6630ca6'
    assert cbc_encrypt(SP_KEY, SP_IV, SP_PT) == SP_CT and cbc_decrypt(SP_KEY, SP_IV, SP_CT) == SP_PT
    for n in range(40):
        assert unpad(pad(bytes(range(n)))) == bytes(range(n))


if __name__ == '__main__':
    self_test()
    print('ok   AES-128: FIPS-197 C.1 and SP 800-38A F.2.1/F.2.2 vectors')
