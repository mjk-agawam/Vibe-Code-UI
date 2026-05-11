import express from 'express';
import { execFileSync } from 'child_process';
import path from 'path';
import { fileURLToPath } from 'url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const app = express();
app.use(express.json());
app.use(express.static(path.join(__dirname, 'public')));

const SF_ORG_ALIAS = 'mjk-260320-scheduler';
const API_VERSION  = 'v63.0';
const TERRITORY_ID = '0HhHu000001TK26KAG';

const COMPANIES = [
  {
    id: 'roofing',
    name: 'Summit Roofing Co.',
    tagline: 'Expert roof replacement & repair',
    workTypeGroupId: '0VSHu000001KAx7OAG',
    workTypeId:      '08qHu000001HT99IAG',
    service: 'Roofing',
    color: '#D4501A',
    icon: 'house',
  },
  {
    id: 'hvac',
    name: 'CoolBreeze HVAC',
    tagline: 'Heating, cooling & air quality solutions',
    workTypeGroupId: '0VSHu000001KAx8OAG',
    workTypeId:      '08qHu000001HT9AIAW',
    service: 'HVAC',
    color: '#1A6DD4',
    icon: 'wind',
  },
  {
    id: 'windows',
    name: 'ClearView Home Solutions',
    tagline: 'Premium window & door replacement',
    workTypeGroupId: '0VSHu000001KAx9OAG',
    workTypeId:      '08qHu000001HT9BIAW',
    service: 'Windows & Doors',
    color: '#5A1AD4',
    icon: 'layout',
  },
  {
    id: 'awnings',
    name: 'ShadeCraft Awnings',
    tagline: 'Custom outdoor shade & awning design',
    workTypeGroupId: '0VSHu000001KAxAOAW',
    workTypeId:      '08qHu000001HT9CIAW',
    service: 'Custom Awnings',
    color: '#1AB85A',
    icon: 'umbrella',
  },
  {
    id: 'solar',
    name: 'SunRise Solar',
    tagline: 'Solar panel installation & energy savings',
    workTypeGroupId: '0VSHu000001KAxBOAW',
    workTypeId:      '08qHu000001HT9DIAW',
    service: 'Solar Panels',
    color: '#D4A81A',
    icon: 'sun',
  },
  {
    id: 'garage',
    name: 'ProLift Garage Doors',
    tagline: 'Garage door installation & replacement',
    workTypeGroupId: '0VSHu000001KAxCOAW',
    workTypeId:      '08qHu000001HT9EIAW',
    service: 'Garage Doors',
    color: '#7A1AD4',
    icon: 'truck',
  },
];

// Cache auth token — refresh only when missing or older than 25 min
let authCache = null;
let authCachedAt = 0;
const AUTH_TTL_MS = 25 * 60 * 1000;

function getSfAuth() {
  const now = Date.now();
  if (authCache && (now - authCachedAt) < AUTH_TTL_MS) return authCache;
  const raw  = execFileSync('sf', ['org', 'display', '--target-org', SF_ORG_ALIAS, '--json'], { encoding: 'utf8' });
  const data = JSON.parse(raw).result;
  authCache    = { instanceUrl: data.instanceUrl, accessToken: data.accessToken };
  authCachedAt = now;
  return authCache;
}

// Pre-warm the auth cache on startup
try { getSfAuth(); console.log('SF auth pre-warmed'); } catch (e) { console.warn('SF auth pre-warm failed:', e.message); }

app.get('/api/companies', (req, res) => {
  res.json(COMPANIES.map(({ id, name, tagline, service, color, icon }) => ({
    id, name, tagline, service, color, icon,
  })));
});

app.post('/api/slots', async (req, res) => {
  try {
    const { companyId, startDate, endDate } = req.body;
    const company = COMPANIES.find(c => c.id === companyId);
    if (!company) return res.status(400).json({ error: 'Unknown company' });

    const { instanceUrl, accessToken } = getSfAuth();

    const payload = {
      startTime:          new Date(startDate).toISOString(),
      endTime:            new Date(endDate).toISOString(),
      workTypeGroupId:    company.workTypeGroupId,
      territoryIds:       [TERRITORY_ID],
      schedulingPolicyId: null,
    };

    const response = await fetch(
      `${instanceUrl}/services/data/${API_VERSION}/connect/scheduling/available-territory-slots`,
      {
        method:  'POST',
        headers: { Authorization: `Bearer ${accessToken}`, 'Content-Type': 'application/json' },
        body: JSON.stringify(payload),
      }
    );

    const data = await response.json();
    if (!response.ok) return res.status(response.status).json(data);

    // Normalize: SF returns { territorySlots: [{ slots: [...] }] }
    const root     = data.result ?? data;
    const rawSlots = root.territorySlots?.[0]?.slots ?? [];

    // Keep only top-of-hour slots for a clean UI (SF returns every 15 min)
    const seen = new Set();
    const timeSlots = rawSlots
      .filter(s => {
        const mins = new Date(s.startTime).getUTCMinutes();
        if (mins !== 0) return false;
        if (seen.has(s.startTime)) return false;
        seen.add(s.startTime);
        return true;
      })
      .map(s => ({ startTime: s.startTime, endTime: s.endTime }))
      .sort((a, b) => a.startTime.localeCompare(b.startTime));

    res.json({ timeSlots });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

app.post('/api/book', async (req, res) => {
  try {
    const { companyId, startTime, endTime, firstName, lastName, email, phone, notes } = req.body;
    const company = COMPANIES.find(c => c.id === companyId);
    if (!company) return res.status(400).json({ error: 'Unknown company' });

    const { instanceUrl, accessToken } = getSfAuth();

    // Connect API: serviceAppointment + lead (required for anonymous/unauthenticated bookings)
    const descriptionParts = [notes ? `Notes: ${notes}` : ''].filter(Boolean);

    const payload = {
      serviceAppointment: {
        workTypeId:         company.workTypeId,
        serviceTerritoryId: TERRITORY_ID,
        schedStartTime:     new Date(startTime).toISOString(),
        schedEndTime:       new Date(endTime).toISOString(),
        appointmentType:    'In Person',
        extendedFields:     descriptionParts.length
          ? [{ name: 'Description', value: descriptionParts.join('\n') }]
          : [],
      },
      lead: {
        firstName:     firstName,
        lastName:      lastName,
        email:         email,
        phone:         phone || '',
        company:       company.name,
        extendedFields: [],
      },
    };

    const response = await fetch(
      `${instanceUrl}/services/data/${API_VERSION}/connect/scheduling/service-appointments`,
      {
        method:  'POST',
        headers: { Authorization: `Bearer ${accessToken}`, 'Content-Type': 'application/json' },
        body: JSON.stringify(payload),
      }
    );

    const data = await response.json();

    if (!response.ok) {
      const sfErrors = Array.isArray(data) ? data : [data];
      const message  = sfErrors.map(e => e.message || e.errorCode || JSON.stringify(e)).join('; ');
      console.error('[/api/book] Salesforce error:', JSON.stringify(sfErrors, null, 2));
      return res.status(response.status).json({ error: message, details: sfErrors });
    }

    // Normalize result wrapper
    const result = data.result ?? data;
    const bookingResult = {
      serviceAppointmentId: result.serviceAppointmentId,
      parentRecordId:       result.parentRecordId,
      assignedResourceIds:  result.assignedResourceIds ?? [],
    };

    // Send confirmation email via Salesforce emailSimple action
    try {
      const apptDate = new Date(startTime).toLocaleString('en-US', {
        weekday: 'long', year: 'numeric', month: 'long', day: 'numeric',
        hour: 'numeric', minute: '2-digit', hour12: true, timeZone: 'America/New_York',
      });
      const emailBody = `
Hi ${firstName},

Your appointment has been confirmed! Here are your details:

  Vendor:    ${company.name}
  Service:   ${company.service} Consultation
  Date/Time: ${apptDate} ET
  Location:  In-Person · Gwinnett County, GA
  Duration:  60 minutes

A ${company.name} specialist will reach out shortly to confirm your address and any additional details.

If you need to reschedule, please reply to this email.

Thank you for choosing Costco Home Services!

Costco Vendor Appointment Team
      `.trim();

      await fetch(
        `${instanceUrl}/services/data/${API_VERSION}/actions/standard/emailSimple`,
        {
          method: 'POST',
          headers: { Authorization: `Bearer ${accessToken}`, 'Content-Type': 'application/json' },
          body: JSON.stringify({
            inputs: [{
              emailAddresses: email,
              emailSubject:   `Confirmed: ${company.service} Consultation on ${new Date(startTime).toLocaleDateString('en-US', { month: 'long', day: 'numeric', year: 'numeric', timeZone: 'America/New_York' })}`,
              emailBody,
              senderType:     'CurrentUser',
            }],
          }),
        }
      );
      console.log(`[/api/book] Confirmation email sent to ${email}`);
    } catch (emailErr) {
      console.warn('[/api/book] Email send failed (non-fatal):', emailErr.message);
    }

    res.json(bookingResult);
  } catch (err) {
    console.error('[/api/book] Exception:', err.message);
    res.status(500).json({ error: err.message });
  }
});

const PORT = process.env.PORT || 3000;
app.listen(PORT, () => {
  console.log(`Costco Scheduler running at http://localhost:${PORT}`);
});
