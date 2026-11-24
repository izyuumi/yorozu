export function deviceStore() {
  const db = new Promise((resolve, reject) => {
    const request = indexedDB.open('yorozu-pairing', 1);
    request.onupgradeneeded = () => request.result.createObjectStore('devices');
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error);
  });
  async function transact(mode, task) {
    const database = await db;
    return new Promise((resolve, reject) => {
      const tx = database.transaction('devices', mode);
      const request = task(tx.objectStore('devices'));
      tx.oncomplete = () => resolve(request.result);
      tx.onabort = () => reject(tx.error ?? request.error);
    });
  }
  return {
    load: () => transact('readonly', (store) => store.get('current')),
    save: (device) => transact('readwrite', (store) => store.put(device, 'current')),
    clear: () => transact('readwrite', (store) => store.delete('current')),
  };
}
