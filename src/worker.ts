interface Env {
	CACHE: R2Bucket;
}

const cacheInfoKey = "nix-cache-info";
const narKey = /^nar\/[A-Za-z0-9+._-]+\.nar(?:\.(?:xz|zst|bz2|gz|lz4|br))?$/;
const narInfoKey = /^[a-z0-9]{32}\.narinfo$/;
const metadataKey = /^_meta\/(?:aarch64-darwin\/[a-f0-9]{40}\.json|latest-success-aarch64-darwin\.json)$/;

function cacheKey(pathname: string): string | null {
	let key: string;

	try {
		key = decodeURIComponent(pathname.slice(1));
	} catch {
		return null;
	}

	if (
		key === cacheInfoKey ||
		narInfoKey.test(key) ||
		narKey.test(key) ||
		metadataKey.test(key)
	) {
		return key;
	}

	return null;
}

function cacheControl(key: string): string {
	if (key.startsWith("_meta/")) {
		return "public, max-age=30, must-revalidate";
	}
	if (key === cacheInfoKey) return "public, max-age=60";
	if (key.endsWith(".narinfo")) return "public, max-age=60";
	return "public, max-age=31536000, immutable";
}

export default {
	async fetch(request: Request, env: Env): Promise<Response> {
		if (request.method !== "GET" && request.method !== "HEAD") {
			return new Response("Method not allowed\n", {
				status: 405,
				headers: { Allow: "GET, HEAD" },
			});
		}

		const key = cacheKey(new URL(request.url).pathname);
		if (!key) return new Response("Not found\n", { status: 404, headers: { "cache-control": "no-store" } });

		const object =
			request.method === "HEAD"
				? await env.CACHE.head(key)
				: await env.CACHE.get(key);
		if (!object) return new Response("Not found\n", { status: 404, headers: { "cache-control": "no-store" } });

		const headers = new Headers();
		object.writeHttpMetadata(headers);
		headers.set("etag", object.httpEtag);
		headers.set("content-length", String(object.size));
		headers.set("cache-control", cacheControl(key));
		if (!headers.has("content-type")) {
			headers.set(
				"content-type",
				key.startsWith("_meta/")
					? "application/json"
					: key.endsWith(".narinfo") || key === cacheInfoKey
					? "text/plain; charset=utf-8"
					: "application/octet-stream",
			);
		}

		return new Response(request.method === "HEAD" ? null : object.body, {
			status: 200,
			headers,
		});
	},
};
