/** Room ID is derived from the Mac public key; the relay never reads payloads. */
export function roomId(macPublicKey: string): string {
  return macPublicKey.trim().toLowerCase();
}
