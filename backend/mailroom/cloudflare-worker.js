// Cloudflare's free Email Routing catch-all calls this email handler.
// Configure INBOUND_URL and the secret INBOUND_EMAIL_SECRET before routing mail.
export default {
  async email(message, env) {
    if (message.rawSize > 10 * 1024 * 1024) {
      message.setReject("Message exceeds the mailbox's 10 MiB limit.");
      return;
    }
    if (!env.INBOUND_EMAIL_SECRET || !env.INBOUND_URL?.startsWith("https://")) {
      throw new Error("Mailbox routing is not configured.");
    }
    const raw = new Uint8Array(await new Response(message.raw).arrayBuffer());
    const timestamp = String(Math.floor(Date.now() / 1000));
    const prefix = new TextEncoder().encode(`${timestamp}\n${message.from}\n${message.to}\n`);
    const signed = new Uint8Array(prefix.length + raw.length);
    signed.set(prefix); signed.set(raw, prefix.length);
    const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(env.INBOUND_EMAIL_SECRET),
      {name:"HMAC", hash:"SHA-256"}, false, ["sign"]);
    const signature = Array.from(new Uint8Array(await crypto.subtle.sign("HMAC", key, signed)),
      value => value.toString(16).padStart(2, "0")).join("");
    const response = await fetch(env.INBOUND_URL, {method:"POST", body:raw,
      headers:{"Content-Type":"application/octet-stream", "X-Mail-Timestamp":timestamp,
        "X-Mail-From":message.from, "X-Mail-To":message.to, "X-Mail-Signature":signature}});
    if (!response.ok) throw new Error("The mailbox did not accept this delivery.");
  }
};
