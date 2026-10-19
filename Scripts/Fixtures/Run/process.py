# Repository-owned process lifecycle fixtures; never executes user code.
import os
import signal
import sys
import time

mode = sys.argv[1]
if mode == 'echo':
    sys.stdout.buffer.write(sys.stdin.buffer.read())
elif mode == 'streams':
    os.write(1, b'\xe6\x97'); time.sleep(.05); os.write(1, b'\xa5\xf0\x9f'); time.sleep(.05); os.write(1, b'\x98\x80')
    os.write(2, '警告'.encode())
elif mode == 'invalid':
    os.write(1, b'a\xffb')
elif mode == 'flood':
    import threading
    def flood(fd):
        for _ in range(768):
            os.write(fd, b'x' * 16384)
    thread = threading.Thread(target=flood, args=(2,)); thread.start(); flood(1); thread.join()
elif mode == 'exit':
    sys.exit(7)
elif mode == 'signal':
    os.kill(os.getpid(), signal.SIGUSR1)
elif mode == 'early-close':
    os.close(0); time.sleep(.15)
elif mode == 'ignore-term':
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    print(os.getpid(), flush=True)
    while True: time.sleep(.1)
elif mode == 'descendants':
    # Parent exits first. Child and grandchild keep pipes open and ignore TERM.
    child = os.fork()
    if child == 0:
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        grandchild = os.fork()
        print(os.getpid(), flush=True)
        while True: time.sleep(.1)
    print(os.getpid(), flush=True)
    time.sleep(.1)
elif mode == 'backpressure':
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    print(os.getpid(), flush=True)
    while True: time.sleep(.1)
