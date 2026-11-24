import { useEffect, useRef, useState } from "react";

export type PairMethod = "scan" | "show" | null;
export type ReceiverCode = { link: string; expiresAt: number; status?: string };
type ScanResult = boolean | string;
type ScannerProps = { onScan: (text: string) => ScanResult | Promise<ScanResult> };

type Decoder = typeof import("jsqr").default;
const qrDecoder = () => import("jsqr").then(module => module.default);

function decodeImage(image: CanvasImageSource, width: number, height: number, canvas: HTMLCanvasElement, decode: Decoder) {
  const scale = Math.min(1, 720 / Math.max(width, height));
  canvas.width = Math.max(1, Math.round(width * scale));
  canvas.height = Math.max(1, Math.round(height * scale));
  const context = canvas.getContext("2d", { willReadFrequently: true });
  if (!context) return undefined;
  context.drawImage(image, 0, 0, canvas.width, canvas.height);
  return decode(context.getImageData(0, 0, canvas.width, canvas.height).data, canvas.width, canvas.height, {
    inversionAttempts: "attemptBoth",
  })?.data;
}

function Scanner({ onScan }: ScannerProps) {
  const video = useRef<HTMLVideoElement>(null);
  const currentScan = useRef(onScan);
  currentScan.current = onScan;
  const busy = useRef(false);
  const alive = useRef(true);
  const previous = useRef<string | undefined>(undefined);
  const [hint, setHint] = useState("Opening your camera…");
  const [cameraUnavailable, setCameraUnavailable] = useState(false);
  const [error, setError] = useState("");
  const accept = async (text: string) => {
    if (busy.current || text === previous.current || !alive.current) return;
    busy.current = true;
    previous.current = text;
    try {
      const result = await currentScan.current(text);
      if (result !== true && alive.current) setError(typeof result === "string" ? result : "This QR code is not a valid invitation for this device.");
    } catch {
      if (alive.current) setError("This QR code couldn’t be read. Use a new code or paste the invitation.");
    } finally { busy.current = false; }
  };
  useEffect(() => {
    alive.current = true;
    let active = true;
    let stream: MediaStream | undefined, decode: Decoder | undefined;
    let timer: ReturnType<typeof setTimeout> | undefined;
    const canvas = document.createElement("canvas"), camera = video.current;
    const stopStream = () => {
      stream?.getTracks().forEach(track => track.stop());
      stream = undefined;
      if (camera) camera.srcObject = null;
    };
    const hide = () => {
      if (!document.hidden) return;
      active = false;
      clearTimeout(timer);
      stopStream();
      setCameraUnavailable(true);
      setHint("Camera paused. Reopen the scanner to use it, or choose a QR image.");
    };
    document.addEventListener("visibilitychange", hide);
    const tick = () => {
      if (!active || !camera) return;
      try {
        if (decode && camera.readyState >= 2 && camera.videoWidth && camera.videoHeight && !busy.current) {
          const text = decodeImage(camera, camera.videoWidth, camera.videoHeight, canvas, decode);
          if (text) void accept(text);
        }
      } catch {
        if (active) {
          stopStream();
          setCameraUnavailable(true);
          setHint("Camera scanning is unavailable. Choose a QR image or paste an invitation.");
        }
        return;
      }
      timer = setTimeout(tick, 200);
    };
    const open = async () => {
      if (!camera || !navigator.mediaDevices?.getUserMedia) {
        setCameraUnavailable(true);
        setHint("Camera scanning is unavailable. Choose a QR image or paste an invitation.");
        return;
      }
      try {
        const source = await navigator.mediaDevices.getUserMedia({ audio: false, video: { facingMode: { ideal: "environment" }, width: { ideal: 640 }, height: { ideal: 480 } } });
        if (!active) {
          source.getTracks().forEach(track => track.stop());
          return;
        }
        stream = source;
        decode = await qrDecoder();
        if (!active) return;
        camera.srcObject = source;
        await camera.play();
        if (active) {
          setHint("Point the camera at an invite QR code.");
          tick();
        }
      } catch {
        stopStream();
        if (active) {
          setCameraUnavailable(true);
          setHint("Camera access is unavailable. Choose a QR image or paste an invitation.");
        }
      }
    };
    void open();
    return () => {
      alive.current = false;
      active = false;
      clearTimeout(timer);
      document.removeEventListener("visibilitychange", hide);
      stopStream();
    };
  }, []);
  return <>
    <p id="qr-camera-hint" role="status">{hint}</p>
    <video ref={video} muted playsInline autoPlay aria-label="Camera preview" aria-describedby="qr-camera-hint" hidden={cameraUnavailable} />
    {error && <p className="qr-error" role="alert">{error}</p>}
    <label className="qr-file">Choose QR image
      <input type="file" accept="image/png,image/jpeg,image/webp" onChange={async (event) => {
        const file = event.currentTarget.files?.[0];
        event.currentTarget.value = "";
        if (!file || busy.current) return;
        if (!["image/png", "image/jpeg", "image/webp"].includes(file.type) || file.size > 8_000_000) {
          setError("Choose a PNG, JPEG, or WebP image below 8 MB.");
          return;
        }
        let image: ImageBitmap | undefined, text: string | undefined;
        try {
          image = await createImageBitmap(file);
          text = decodeImage(image, image.width, image.height, document.createElement("canvas"), await qrDecoder());
        } catch {
          if (alive.current) setError("This image couldn’t be opened.");
          return;
        } finally { image?.close(); }
        if (!alive.current) return;
        if (!text) { setError("No QR code was found in this image."); return; }
        previous.current = undefined;
        setError("");
        await accept(text);
      }} />
    </label>
  </>;
}

function CodeImage({ text }: { text: string }) {
  const frame = useRef<HTMLDivElement>(null);
  const canvas = useRef<HTMLCanvasElement>(null);
  const [error, setError] = useState(false), [large, setLarge] = useState(false);
  useEffect(() => {
    const node = canvas.current, box = frame.current;
    if (!node || !box) return;
    let active = true, observer: ResizeObserver | undefined, resize: (() => void) | undefined;
    setError(false);
    void import("qrcode-generator").then(({ default: qrcode }) => {
      if (!active) return;
      const code = qrcode(0, "M");
      code.addData(text);
      code.make();
      const modules = code.getModuleCount(), margin = 4, tiles = modules + margin * 2;
      const ctx = node.getContext("2d");
      if (!ctx) throw new Error("QR drawing unavailable");
      const paint = () => {
        const density = window.devicePixelRatio || 1;
        const size = Math.floor(box.getBoundingClientRect().width * density);
        if (!size) return;
        const cell = Math.max(1, Math.floor(size / tiles));
        node.width = node.height = tiles * cell;
        node.style.width = node.width / density + "px";
        ctx.fillStyle = "#fff";
        ctx.fillRect(0, 0, node.width, node.height);
        ctx.fillStyle = "#000";
        for (let row = 0; row < modules; row++) {
          for (let col = 0; col < modules; col++) {
            if (code.isDark(row, col)) ctx.fillRect((col + margin) * cell, (row + margin) * cell, cell, cell);
          }
        }
      };
      paint();
      observer = new ResizeObserver(paint);
      observer.observe(box);
      resize = paint;
      window.addEventListener("resize", resize);
    }).catch(() => { if (active) setError(true); });
    return () => {
      active = false;
      observer?.disconnect();
      if (resize) window.removeEventListener("resize", resize);
      node.width = node.height = 0;
    };
  }, [text]);
  return <>
    <div ref={frame} className={large ? "device-qr-frame enlarged" : "device-qr-frame"}>
      <canvas ref={canvas} className="device-qr" role="img" aria-label="One-time QR pairing request" hidden={error} />
    </div>
    {error ? <p role="alert">This QR code couldn’t be drawn. Try a new code or paste an invitation.</p> :
      <button className="qr-size-button" type="button" onClick={() => setLarge(value => !value)}>{large ? "Reduce QR code size" : "Enlarge QR code"}</button>}
  </>;
}

export function PairingMethods({ mode, onMode, onScan, receiver, receiverError, restart, showHint, scanHint, focusPaste }: {
  mode: PairMethod;
  onMode: (mode: PairMethod) => void;
  onScan: ScannerProps["onScan"];
  receiver?: ReceiverCode | null;
  receiverError?: string;
  restart: () => void;
  showHint: string;
  scanHint: string;
  focusPaste: () => void;
}) {
  const [now, setNow] = useState(Date.now());
  const heading = useRef<HTMLHeadingElement>(null);
  const previousMode = useRef<PairMethod>(null);
  useEffect(() => {
    if (mode) heading.current?.focus();
    else if (previousMode.current) focusPaste();
    previousMode.current = mode;
  }, [mode]);
  useEffect(() => {
    if (mode !== "show") return;
    setNow(Date.now());
    const timer = setInterval(() => setNow(Date.now()), 1000);
    return () => clearInterval(timer);
  }, [mode]);
  if (!mode) return <div className="pair-methods" aria-label="QR pairing">
    <button type="button" onClick={() => onMode("scan")}>Scan QR code</button>
    <button type="button" onClick={() => onMode("show")}>Show QR code</button>
  </div>;
  const expired = receiver && receiver.expiresAt <= now;
  return <section className="qr-panel" aria-label={mode === "scan" ? "Scan an invitation" : "Show a pairing request"}>
    <h1 ref={heading} tabIndex={-1}>{mode === "scan" ? "Scan QR code" : "Show QR code"}</h1>
    {mode === "scan" ? <><p>{scanHint}</p><Scanner onScan={onScan} /></> : <>
      <p>{showHint}</p>
      {receiver && !expired && !receiverError ? <><CodeImage text={receiver.link} />
        <p className="help">Treat the code as private. It expires in {Math.max(1, Math.ceil((receiver.expiresAt - now) / 60_000))} min.</p>
        <p role="status">{receiver.status || "Waiting for an invitation…"}</p></> :
        <p role="status">{receiverError || (expired ? "This code expired." : "Preparing a one-time code…")}</p>}
      {(expired || receiverError) && <button type="button" onClick={restart}>Get a new QR code</button>}
    </>}
    <button type="button" onClick={() => onMode(null)}>Paste invite link instead</button>
  </section>;
}
