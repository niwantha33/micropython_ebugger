import time

def leaf(a, b):
    c = a + b
    return c

def middle(n):
    total = 0
    for i in range(n):
        total = leaf(total, i)
    return total

def outer():
    while True:
        r = middle(4)
        print("result=", r)
        time.sleep(1)
