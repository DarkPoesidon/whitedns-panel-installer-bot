const CF_API_BASE = 'https://api.cloudflare.com/client/v4';

/**
 * Returns appropriate Cloudflare headers for either:
 * - Scoped API Token (Bearer <TOKEN>)
 * - Global API Key (X-Auth-Email + X-Auth-Key)
 */
export function getAuthHeaders(authInput) {
  const trimmed = (authInput || '').trim();
  if (trimmed.includes(':') && trimmed.includes('@')) {
    const parts = trimmed.split(':');
    const email = parts[0].trim();
    const key = parts.slice(1).join(':').trim();
    return {
      'X-Auth-Email': email,
      'X-Auth-Key': key,
      'Content-Type': 'application/json'
    };
  }
  return {
    'Authorization': `Bearer ${trimmed}`,
    'Content-Type': 'application/json'
  };
}

/**
 * Validates Cloudflare credentials (supports both API Token and Global Key)
 * Automatically falls back to pure Bearer Token if email:token was provided.
 */
export async function verifyToken(authInput) {
  try {
    const headers = getAuthHeaders(authInput);
    const endpoint = headers['X-Auth-Key'] ? `${CF_API_BASE}/user` : `${CF_API_BASE}/user/tokens/verify`;

    const res = await fetch(endpoint, {
      method: 'GET',
      headers
    });

    if (res.ok) {
      const data = await res.json();
      if (data.success) {
        return { ok: true, resolvedAuth: authInput };
      }
    }

    // Fallback: If authInput was "email:key", test if "key" is actually a Bearer Token
    if (authInput.includes(':') && authInput.includes('@')) {
      const rawKey = authInput.split(':').slice(1).join(':').trim();
      const fallbackRes = await fetch(`${CF_API_BASE}/user/tokens/verify`, {
        method: 'GET',
        headers: {
          'Authorization': `Bearer ${rawKey}`,
          'Content-Type': 'application/json'
        }
      });
      if (fallbackRes.ok) {
        const fallbackData = await fallbackRes.json();
        if (fallbackData.success) {
          return { ok: true, resolvedAuth: rawKey };
        }
      }
    }

    return { ok: false, error: 'کلید یا توکن نامعتبر است. لطفاً دقت فرمایید.' };
  } catch (err) {
    return { ok: false, error: err.message };
  }
}

/**
 * Retrieves the list of active zones (domains) for the credentials
 */
export async function listZones(authInput) {
  try {
    const headers = getAuthHeaders(authInput);
    const res = await fetch(`${CF_API_BASE}/zones?status=active&per_page=50`, {
      method: 'GET',
      headers
    });

    if (!res.ok) {
      return { ok: false, error: `Failed to fetch zones: HTTP ${res.status}` };
    }

    const data = await res.json();
    if (!data.success) {
      return { ok: false, error: data.errors?.[0]?.message || 'Unknown API error' };
    }

    const zones = (data.result || []).map(z => ({
      id: z.id,
      name: z.name
    }));

    return { ok: true, zones };
  } catch (err) {
    return { ok: false, error: err.message };
  }
}

/**
 * Ensures a DNS record exists with the exact specified content and proxied=false
 */
async function upsertDnsRecord(authInput, zoneId, type, name, content, proxied = false) {
  const headers = getAuthHeaders(authInput);

  // Find existing record
  const searchUrl = `${CF_API_BASE}/zones/${zoneId}/dns_records?type=${type}&name=${encodeURIComponent(name)}`;
  const searchRes = await fetch(searchUrl, { headers });
  const searchData = await searchRes.json();
  const existing = searchData.result?.[0];

  const payload = {
    type,
    name,
    content,
    ttl: 1, // Auto TTL
    proxied: !!proxied
  };

  if (existing) {
    // Check if update is needed
    if (existing.content === content && existing.proxied === proxied) {
      return { ok: true, action: 'kept', id: existing.id };
    }

    const updateRes = await fetch(`${CF_API_BASE}/zones/${zoneId}/dns_records/${existing.id}`, {
      method: 'PUT',
      headers,
      body: JSON.stringify(payload)
    });
    const updateData = await updateRes.json();
    if (!updateData.success) {
      throw new Error(`Failed to update ${type} record ${name}: ${updateData.errors?.[0]?.message}`);
    }
    return { ok: true, action: 'updated', id: existing.id };
  }

  // Create new record
  const createRes = await fetch(`${CF_API_BASE}/zones/${zoneId}/dns_records`, {
    method: 'POST',
    headers,
    body: JSON.stringify(payload)
  });
  const createData = await createRes.json();
  if (!createData.success) {
    throw new Error(`Failed to create ${type} record ${name}: ${createData.errors?.[0]?.message}`);
  }
  return { ok: true, action: 'created', id: createData.result.id };
}

/**
 * Creates the complete triple DNS configuration required for WhiteDNS Soar Server:
 * 1. A record:     ns-soar.<domain> -> vpsIp (Proxy OFF)
 * 2. NS record:    soar.<domain>    -> ns-soar.<domain>
 * 3. A record:     panel.<domain>   -> vpsIp (Proxy OFF)
 */
export async function setupSoarDnsRecords(authInput, zoneId, domain, vpsIp) {
  const cleanDomain = domain.toLowerCase().trim();
  const nsHost = `ns-soar.${cleanDomain}`;
  const tunnelZone = `soar.${cleanDomain}`;
  const panelHost = `panel.${cleanDomain}`;

  // 1. A record: ns-soar.<domain> -> vpsIp (Proxy OFF)
  const nsARecord = await upsertDnsRecord(authInput, zoneId, 'A', nsHost, vpsIp, false);

  // 2. NS record: soar.<domain> -> ns-soar.<domain>
  const soarNsRecord = await upsertDnsRecord(authInput, zoneId, 'NS', tunnelZone, nsHost, false);

  // 3. A record: panel.<domain> -> vpsIp (Proxy OFF)
  const panelARecord = await upsertDnsRecord(authInput, zoneId, 'A', panelHost, vpsIp, false);

  return {
    ok: true,
    nsARecord,
    soarNsRecord,
    panelARecord,
    records: {
      nsHost,
      tunnelZone,
      panelHost,
      vpsIp
    }
  };
}

/**
 * Deletes the triple DNS configuration for WhiteDNS from Cloudflare
 */
export async function deleteSoarDnsRecords(authInput, zoneId, domain) {
  const cleanDomain = domain.toLowerCase().trim();
  const targets = [
    { type: 'A', name: `ns-soar.${cleanDomain}` },
    { type: 'NS', name: `soar.${cleanDomain}` },
    { type: 'A', name: `panel.${cleanDomain}` }
  ];

  const headers = getAuthHeaders(authInput);
  let deletedCount = 0;

  for (const t of targets) {
    try {
      const searchUrl = `${CF_API_BASE}/zones/${zoneId}/dns_records?type=${t.type}&name=${encodeURIComponent(t.name)}`;
      const searchRes = await fetch(searchUrl, { headers });
      const searchData = await searchRes.json();
      if (searchData.result?.length) {
        for (const r of searchData.result) {
          await fetch(`${CF_API_BASE}/zones/${zoneId}/dns_records/${r.id}`, {
            method: 'DELETE',
            headers
          });
          deletedCount++;
        }
      }
    } catch (e) {
      // Ignore individual record deletion failure
    }
  }

  return { ok: true, deletedCount };
}

/**
 * Retrieves all DNS records for a given zone
 */
export async function listDnsRecords(authInput, zoneId, page = 1, perPage = 50) {
  try {
    const headers = getAuthHeaders(authInput);
    const res = await fetch(`${CF_API_BASE}/zones/${zoneId}/dns_records?page=${page}&per_page=${perPage}&order=type`, {
      method: 'GET',
      headers
    });
    if (!res.ok) {
      return { ok: false, error: `خطا در دریافت رکوردها: HTTP ${res.status}` };
    }
    const data = await res.json();
    if (!data.success) {
      return { ok: false, error: data.errors?.[0]?.message || 'خطا در ارتباط با کلودفلر' };
    }
    return {
      ok: true,
      records: data.result || [],
      info: data.result_info || {}
    };
  } catch (err) {
    return { ok: false, error: err.message };
  }
}

/**
 * Fetches a single DNS record by ID
 */
export async function getDnsRecord(authInput, zoneId, recordId) {
  try {
    const headers = getAuthHeaders(authInput);
    const res = await fetch(`${CF_API_BASE}/zones/${zoneId}/dns_records/${recordId}`, {
      method: 'GET',
      headers
    });
    const data = await res.json();
    if (!data.success) {
      return { ok: false, error: data.errors?.[0]?.message || 'رکورد یافت نشد.' };
    }
    return { ok: true, record: data.result };
  } catch (err) {
    return { ok: false, error: err.message };
  }
}

/**
 * Creates a new DNS record in Cloudflare
 */
export async function createDnsRecord(authInput, zoneId, { type, name, content, proxied = false, ttl = 1, comment = 'WhiteDNS Manager' }) {
  try {
    const headers = getAuthHeaders(authInput);
    const payload = {
      type: type.toUpperCase(),
      name,
      content,
      proxied: !!proxied,
      ttl: Number(ttl) || 1,
      comment
    };
    const res = await fetch(`${CF_API_BASE}/zones/${zoneId}/dns_records`, {
      method: 'POST',
      headers,
      body: JSON.stringify(payload)
    });
    const data = await res.json();
    if (!data.success) {
      return { ok: false, error: data.errors?.[0]?.message || 'خطا در ثبت رکورد' };
    }
    return { ok: true, record: data.result };
  } catch (err) {
    return { ok: false, error: err.message };
  }
}

/**
 * Updates an existing DNS record in Cloudflare
 */
export async function updateDnsRecord(authInput, zoneId, recordId, updates) {
  try {
    const headers = getAuthHeaders(authInput);
    const res = await fetch(`${CF_API_BASE}/zones/${zoneId}/dns_records/${recordId}`, {
      method: 'PATCH',
      headers,
      body: JSON.stringify(updates)
    });
    const data = await res.json();
    if (!data.success) {
      return { ok: false, error: data.errors?.[0]?.message || 'خطا در به‌روزرسانی رکورد' };
    }
    return { ok: true, record: data.result };
  } catch (err) {
    return { ok: false, error: err.message };
  }
}

/**
 * Deletes a single DNS record by ID
 */
export async function deleteDnsRecord(authInput, zoneId, recordId) {
  try {
    const headers = getAuthHeaders(authInput);
    const res = await fetch(`${CF_API_BASE}/zones/${zoneId}/dns_records/${recordId}`, {
      method: 'DELETE',
      headers
    });
    const data = await res.json();
    if (!data.success) {
      return { ok: false, error: data.errors?.[0]?.message || 'خطا در حذف رکورد' };
    }
    return { ok: true, result: data.result };
  } catch (err) {
    return { ok: false, error: err.message };
  }
}
