const server = Bun.serve({
  async fetch(req) {
    const url = new URL(req.url);
    const filePath = `./server${url.pathname}`;

    const file = Bun.file(filePath);
    const exists = await file.exists();
    if (exists) {
      return new Response(file);
    }

    return new Response("Not Found", { status: 404 });
  },
  port: 3000,
  hostname: "0.0.0.0",
});

console.log(`Server running at ${server.url}`);
console.log(`Access from your network at http://192.168.1.41:${server.port}`);
