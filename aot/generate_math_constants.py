#!/usr/bin/env python3
"""Reproduce the pure-QLang trigonometric reducer's 1216-bit 2/pi table."""
from decimal import Decimal, localcontext


def constant(precision):
    with localcontext() as context:
        context.prec = precision
        def atan_inverse(n):
            x = Decimal(1) / n
            term = x
            total = x
            k = 3
            while True:
                term *= -x * x
                updated = total + term / k
                if updated == total:
                    return total
                total = updated
                k += 2
        pi = 16 * atan_inverse(5) - 4 * atan_inverse(239)
        return int((2 / pi) * (Decimal(2) ** 1216))


def limbs():
    value = constant(450)
    assert value == constant(500), 'insufficient generation precision'
    result = []
    for _ in range(76):
        result.append(value & 65535)
        value >>= 16
    assert value == 0
    return result


if __name__ == '__main__':
    print('let __two_over_pi = ' + str(limbs()) + ';')
