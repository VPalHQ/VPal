"""Ed25519 signature check (RFC 8032), pure Python, verify only. Discord signs every interaction it sends the bot,
and the bot must reject anything without a valid signature. Fast enough for chat commands (a few ms each)."""
import hashlib

p = 2 ** 255 - 19
L = 2 ** 252 + 27742317777372353535851937790883648493
d = -121665 * pow(121666, p - 2, p) % p
SQRT_M1 = pow(2, (p - 1) // 4, p)


def _sha512_int(b):
    return int.from_bytes(hashlib.sha512(b).digest(), 'little')


def _add(P, Q):
    # extended coordinates (X, Y, Z, T)
    A = (P[1] - P[0]) * (Q[1] - Q[0]) % p
    B = (P[1] + P[0]) * (Q[1] + Q[0]) % p
    C = 2 * P[3] * Q[3] * d % p
    D = 2 * P[2] * Q[2] % p
    E, F, G, H = B - A, D - C, D + C, B + A
    return (E * F % p, G * H % p, F * G % p, E * H % p)


def _mul(s, P):
    Q = (0, 1, 1, 0)
    while s > 0:
        if s & 1: Q = _add(Q, P)
        P = _add(P, P)
        s >>= 1
    return Q


def _equal(P, Q):
    return (P[0] * Q[2] - Q[0] * P[2]) % p == 0 and (P[1] * Q[2] - Q[1] * P[2]) % p == 0


def _recover_x(y, sign):
    if y >= p: return None
    x2 = (y * y - 1) * pow(d * y * y + 1, p - 2, p)
    if x2 == 0: return None if sign else 0
    x = pow(x2, (p + 3) // 8, p)
    if (x * x - x2) % p != 0: x = x * SQRT_M1 % p
    if (x * x - x2) % p != 0: return None
    if (x & 1) != sign: x = p - x
    return x


def _decompress(s):
    if len(s) != 32: return None
    y = int.from_bytes(s, 'little')
    sign = y >> 255
    y &= (1 << 255) - 1
    x = _recover_x(y, sign)
    if x is None: return None
    return (x, y, 1, x * y % p)


G = (lambda y: (_recover_x(y, 0), y, 1, _recover_x(y, 0) * y % p))(4 * pow(5, p - 2, p) % p)


def verify(public_key, message, signature):
    """public_key: 32 bytes, signature: 64 bytes. True only for a valid signature."""
    try:
        if len(public_key) != 32 or len(signature) != 64: return False
        A = _decompress(public_key)
        if not A: return False
        Rs = signature[:32]
        R = _decompress(Rs)
        if not R: return False
        s = int.from_bytes(signature[32:], 'little')
        if s >= L: return False
        h = _sha512_int(Rs + public_key + message) % L
        return _equal(_mul(s, G), _add(R, _mul(h, A)))
    except Exception:
        return False
