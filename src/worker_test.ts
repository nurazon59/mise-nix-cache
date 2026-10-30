import worker from "./worker.ts";

const sha = "a".repeat(40);
const hash = "a".repeat(32);
const objects = new Map([
	["nix-cache-info", "StoreDir: /nix/store\n"],
	[`${hash}.narinfo`, "StorePath: /nix/store/example\n"],
	["nar/example.nar.zst", "archive"],
	[`_meta/aarch64-darwin/${sha}.json`, "{}"],
	["_meta/latest-success-aarch64-darwin.json", "{}"],
]);

const env = {
	CACHE: {
		head(key: string) { return this.object(key); },
		get(key: string) { return this.object(key); },
		object(key: string) {
			const body = objects.get(key);
			if (body === undefined) return null;
			return {
				body,
				size: new TextEncoder().encode(body).length,
				httpEtag: '"etag"',
				writeHttpMetadata() {},
			};
		},
	},
} as never;

function assert(condition: boolean): asserts condition {
	if (!condition) throw new Error("assertion failed");
}

Deno.test("serves cache objects with GET and HEAD", async () => {
	for (const [key, body] of objects) {
		const response = await worker.fetch(new Request(`https://cache.test/${key}`), env);
		assert(response.status === 200);
		assert(await response.text() === body);
		assert(response.headers.get("content-length") === String(body.length));
		assert(response.headers.get("etag") === '"etag"');
		const head = await worker.fetch(new Request(`https://cache.test/${key}`, { method: "HEAD" }), env);
		assert(head.status === 200);
		assert(await head.text() === "");
		assert(head.headers.get("content-length") === String(body.length));
		assert(head.headers.get("cache-control") === response.headers.get("cache-control"));
	}
});

Deno.test("limits routes and prevents caching misses", async () => {
	for (const key of ["missing", `${hash}.narinfo`, "_meta/private.json", "%invalid", "nar/a.nar/other"]) {
		const path = key === `${hash}.narinfo` ? `${"b".repeat(32)}.narinfo` : key;
		const response = await worker.fetch(new Request(`https://cache.test/${path}`), env);
		assert(response.status === 404);
		assert(response.headers.get("cache-control") === "no-store");
	}
	const response = await worker.fetch(new Request("https://cache.test/nix-cache-info", { method: "PUT" }), env);
	assert(response.status === 405);
	assert(response.headers.get("allow") === "GET, HEAD");
});

Deno.test("sets cache policy by object type", async () => {
	for (const [key, policy] of [
		["nix-cache-info", "public, max-age=60"],
		[`${hash}.narinfo`, "public, max-age=60"],
		["nar/example.nar.zst", "public, max-age=31536000, immutable"],
		[`_meta/aarch64-darwin/${sha}.json`, "public, max-age=30, must-revalidate"],
		["_meta/latest-success-aarch64-darwin.json", "public, max-age=30, must-revalidate"],
	]) {
		const response = await worker.fetch(new Request(`https://cache.test/${key}`), env);
		assert(response.headers.get("cache-control") === policy);
	}
});
