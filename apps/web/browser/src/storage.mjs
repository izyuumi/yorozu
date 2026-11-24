export function deviceStore() {
  const open = () => new Promise((resolve, reject) => {
    const request = indexedDB.open('yorozu-pairing', 1);
    request.onupgradeneeded = () => request.result.createObjectStore('devices');
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error);
  });
  let db = open();
  async function transact(mode, task) {
    const database = await db;
    return new Promise((resolve, reject) => {
      const tx = database.transaction('devices', mode);
      const request = task(tx.objectStore('devices'));
      tx.oncomplete = () => resolve(request.result);
      tx.onabort = () => reject(tx.error ?? request.error);
    });
  }
  const load = () => transact('readonly', (store) => store.get('current'));
  return {
    load,
    async save(device) {
      await transact('readwrite', (store) => store.put(device, 'current'));
      (await db).close();
      db = open();
      const saved = await load();
      const matches = (key, name) => key?.type === 'private' && key.extractable === false && key.algorithm?.name === name;
      if (saved?.room !== device.room || !matches(saved.identity?.noisePrivate, 'X25519') ||
          !matches(saved.identity?.signingPrivate, 'Ed25519')) {
        await transact('readwrite', (store) => store.delete('current'));
        throw new Error('Browser did not preserve pairing keys');
      }
    },
    clear: () => transact('readwrite', (store) => store.delete('current')),
  };
}
