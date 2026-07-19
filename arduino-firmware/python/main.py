from arduino.app_utils import *
import threading, time, json, socket
from http.server import HTTPServer, BaseHTTPRequestHandler

try:
    import depthai as dai
    HAS_CAM = True
except ImportError:
    HAS_CAM = False
    print("!! depthai not in app venv - camera disabled", flush=True)

state = {"left": None, "right": None, "up": None}
state_lock = threading.Lock()

EVENT_PORT = 5005
HTTP_PORT  = 8080

MIN_CONF       = 0.6
CONFIRM_FRAMES = 5
GONE_FRAMES    = 15
LEFT_EDGE      = 0.35
RIGHT_EDGE     = 0.65

def sensor_loop():
    time.sleep(10)
    while True:
        try:
            vl = Bridge.call("read_mm", 0)
            md = Bridge.call("read_mm", 1)
            with state_lock:
                state["left"]  = round(vl / 1000.0, 3) if vl > 0 else state["left"]
                state["right"] = round(md / 1000.0, 3) if md > 0 else state["right"]
        except Exception:
            pass
        time.sleep(0.05)

class TofHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/tof":
            with state_lock:
                body = json.dumps(state).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        else:
            self.send_response(404)
            self.end_headers()
    def log_message(self, *args):
        pass

def http_loop():
    try:
        print(f"[http] starting on 0.0.0.0:{HTTP_PORT}", flush=True)
        srv = HTTPServer(("0.0.0.0", HTTP_PORT), TofHandler)
        print("[http] server bound, serving", flush=True)
        srv.serve_forever()
    except Exception as e:
        print(f"[http] SERVER DIED: {e}", flush=True)

udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
udp.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)

def emit(obj, direction, conf):
    msg = {
        "timestamp":    int(time.time()),
        "object_class": obj,
        "direction":    direction,
        "confidence":   round(float(conf), 2),
    }
    line = json.dumps(msg)
    print("EVENT " + line, flush=True)
    try:
        udp.sendto(line.encode(), ("255.255.255.255", EVENT_PORT))
    except Exception as e:
        print(f"[udp] send failed: {e}", flush=True)

def camera_loop():
    tracked = {}
    with dai.Pipeline() as pipeline:
        cam = pipeline.create(dai.node.Camera).build()
        nn  = pipeline.create(dai.node.DetectionNetwork).build(
            cam, dai.NNModelDescription("yolov6-nano"))
        labels = nn.getClasses()
        q = nn.out.createOutputQueue()
        pipeline.start()
        print("caneOS: camera running", flush=True)

        while pipeline.isRunning():
            seen = {}
            for d in q.get().detections:
                if d.confidence < MIN_CONF:
                    continue
                cx = (d.xmin + d.xmax) / 2
                direction = ("left" if cx < LEFT_EDGE
                             else "right" if cx > RIGHT_EDGE else "center")
                obj = labels[d.label]
                if obj not in seen or d.confidence > seen[obj][1]:
                    seen[obj] = (direction, float(d.confidence))

            for obj, (direction, conf) in seen.items():
                e = tracked.get(obj)
                if e is None:
                    tracked[obj] = {"dir": direction, "seen": 1,
                                    "missing": 0, "fired": False}
                    continue
                e["seen"] += 1
                e["missing"] = 0
                if e["seen"] < CONFIRM_FRAMES:
                    continue
                if not e["fired"]:
                    e["fired"] = True
                    e["dir"] = direction
                    emit(obj, direction, conf)
                elif direction != e["dir"]:
                    e["dir"] = direction
                    emit(obj, direction, conf)

            for obj in list(tracked):
                if obj in seen:
                    continue
                tracked[obj]["missing"] += 1
                if tracked[obj]["missing"] > GONE_FRAMES:
                    del tracked[obj]

def heartbeat():
    time.sleep(12)
    while True:
        with state_lock:
            print(f"[tof] {state}", flush=True)
        time.sleep(5)

threading.Thread(target=sensor_loop, daemon=True).start()
threading.Thread(target=http_loop, daemon=True).start()
threading.Thread(target=heartbeat, daemon=True).start()
if HAS_CAM:
    threading.Thread(target=camera_loop, daemon=True).start()
App.run()