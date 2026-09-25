# esp-relay

Pairs a device shared from the ESP Web Toolkit's `/relay` page with one remote browser, and passes the bytes (RFC 2217) between them without looking inside.

```sh
npm install
npm start          # listens on :8787, or $PORT
```

Share from `/relay` with the relay server set to `ws://localhost:8787` (or `wss://` behind a TLS proxy, optionally under a path prefix), then hand out the link it shows. Whoever has the link can use the device until sharing stops.
