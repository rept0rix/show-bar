export default {
  async fetch(request, env) {
    const url = new URL(request.url)
    if (request.method === "POST" && url.pathname === "/login") {
      const form = await request.formData()
      const password = String(form.get("password") || "")
      if (!env.ADMIN_PASSWORD || password !== env.ADMIN_PASSWORD) {
        return page(login("That password is wrong."), false)
      }
      const token = await seal(env.SESSION_SECRET)
      return new Response(null, {
        status: 302,
        headers: {
          Location: "/",
          "Set-Cookie": `sb_admin=${token}; HttpOnly; Secure; SameSite=Lax; Path=/; Max-Age=1209600`,
        },
      })
    }
    if (url.pathname === "/logout") {
      return new Response(null, {
        status: 302,
        headers: {
          Location: "/",
          "Set-Cookie": "sb_admin=; HttpOnly; Secure; SameSite=Lax; Path=/; Max-Age=0",
        },
      })
    }
    const cookie = readCookie(request.headers.get("cookie") || "", "sb_admin")
    if (!(await open(cookie, env.SESSION_SECRET))) {
      return page(login(""), false)
    }
    const files = await releases()
    const total = files.reduce((sum, file) => sum + file.downloads, 0)
    const rows = files.map((file) => `<tr><td>${esc(file.version)}</td><td>${esc(file.name)}</td><td>${file.downloads}</td></tr>`).join("")
    const body = `<p class="total">${total}</p><p class="note">Each number is a file download. One person can count more than once. This does not say who is running Show Bar.</p><table><tr><th>Version</th><th>File</th><th>Downloads</th></tr>${rows}</table><p><a href="/logout">Log out</a></p>`
    return page(body, true)
  },
}

function login(error) {
  const note = error ? `<p class="err">${esc(error)}</p>` : ""
  return `${note}<form method="post" action="/login"><label>Password<input type="password" name="password" autofocus></label><button type="submit">Open</button></form>`
}

function page(body, inside) {
  const html = `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="robots" content="noindex"><title>Show Bar admin</title><style>body{font:16px -apple-system,sans-serif;background:#161616;color:#f4f4f4;margin:48px auto;max-width:640px;padding:0 20px}table{width:100%;border-collapse:collapse}td,th{text-align:left;padding:8px 0;border-bottom:1px solid #333}.total{font-size:48px;margin:0}.note,.err{color:#aaa}a{color:#fff}input{display:block;margin:8px 0 16px;padding:8px;width:100%;box-sizing:border-box}button{padding:8px 14px}</style></head><body><h1>Show Bar</h1>${body}</body></html>`
  return new Response(html, {
    headers: {
      "content-type": "text/html; charset=utf-8",
      "cache-control": "no-store",
      "x-robots-tag": "noindex",
    },
  })
}

async function releases() {
  const response = await fetch("https://api.github.com/repos/rept0rix/show-bar/releases?per_page=20", {
    headers: { "user-agent": "ShowBar", accept: "application/vnd.github+json" },
  })
  if (!response.ok) return []
  const list = await response.json()
  const files = []
  for (const release of list) {
    for (const asset of release.assets || []) {
      files.push({ version: release.tag_name, name: asset.name, downloads: asset.download_count || 0 })
    }
  }
  return files
}

function readCookie(header, name) {
  const part = header.split(";").map((item) => item.trim()).find((item) => item.startsWith(name + "="))
  return part ? decodeURIComponent(part.slice(name.length + 1)) : ""
}

async function seal(secret) {
  const exp = Date.now() + 14 * 24 * 60 * 60 * 1000
  const sig = await mac(secret, String(exp))
  return `${exp}.${sig}`
}

async function open(token, secret) {
  if (!token || !secret) return false
  const [exp, sig] = token.split(".")
  if (!exp || !sig || Number(exp) < Date.now()) return false
  return (await mac(secret, exp)) === sig
}

async function mac(secret, data) {
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret || ""), { name: "HMAC", hash: "SHA-256" }, false, ["sign"])
  const sig = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(data))
  return btoa(String.fromCharCode(...new Uint8Array(sig))).replaceAll("+", "-").replaceAll("/", "_").replaceAll("=", "")
}

function esc(value) {
  return String(value).replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;")
}
