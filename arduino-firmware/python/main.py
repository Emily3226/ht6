from arduino.app_utils import *
import threading, time

def poll():
    time.sleep(3)
    while True:
        out = []
        for i in range(2):
            st = Bridge.call("status", i)
            mm = Bridge.call("read_mm", i)
            if not st:
                out.append(f"s{i}: INIT FAILED")
            elif mm > 0:
                out.append(f"s{i}: {mm}mm")
            else:
                out.append(f"s{i}: timeout")
        print("   ".join(out), flush=True)
        time.sleep(0.3)

threading.Thread(target=poll, daemon=True).start()
App.run()