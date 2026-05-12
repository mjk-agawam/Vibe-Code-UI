import { LightningElement, track } from 'lwc';
import getCompaniesApex      from '@salesforce/apex/CostcoSchedulerController.getCompanies';
import getAvailableSlotsApex from '@salesforce/apex/CostcoSchedulerController.getAvailableSlots';
import createBookingApex     from '@salesforce/apex/CostcoSchedulerController.createBooking';
import COSTCO_LOGO           from '@salesforce/resourceUrl/CostcoLogo';

const MONTH_NAMES = ['January','February','March','April','May','June',
                     'July','August','September','October','November','December'];

// Hardcoded WorkType IDs (must match org setup)
const COMPANY_IDS = {
    roofing: { workTypeGroupId:'0VSHu000001KAx7OAG', workTypeId:'08qHu000001HT99IAG' },
    hvac:    { workTypeGroupId:'0VSHu000001KAx8OAG', workTypeId:'08qHu000001HT9AIAW' },
    windows: { workTypeGroupId:'0VSHu000001KAx9OAG', workTypeId:'08qHu000001HT9BIAW' },
    awnings: { workTypeGroupId:'0VSHu000001KAxAOAW', workTypeId:'08qHu000001HT9CIAW' },
    solar:   { workTypeGroupId:'0VSHu000001KAxBOAW', workTypeId:'08qHu000001HT9DIAW' },
    garage:  { workTypeGroupId:'0VSHu000001KAxCOAW', workTypeId:'08qHu000001HT9EIAW' }
};

export default class CostcoScheduler extends LightningElement {

    costcoLogoUrl = COSTCO_LOGO;

    // Screens: companies | booking | form | confirm
    @track currentScreen    = 'companies';
    @track companies        = [];
    @track loadingCompanies = false;
    @track selectedCompany  = null;

    // Calendar state
    @track calYear    = new Date().getFullYear();
    @track calMonth   = new Date().getMonth();
    @track slotsByDate = {};
    @track loadingSlots = false;
    @track selectedDate = null;
    @track selectedSlot = null;

    _loadedMonths  = new Set();
    _loadingMonths = new Set();

    // Form fields
    @track firstName = '';
    @track lastName  = '';
    @track email     = '';
    @track phone     = '';
    @track notes     = '';

    // Booking result
    @track bookingInProgress = false;
    @track confirmApptId     = '';

    // Toast
    @track showToast = false;
    @track toastMsg  = '';

    // ── Lifecycle ──────────────────────────────────────────────────────────
    connectedCallback() {
        this._loadCompanies();
    }

    async _loadCompanies() {
        this.loadingCompanies = true;
        try {
            const raw = await getCompaniesApex();
            this.companies = raw.map(c => ({
                ...c,
                iconStyle:    `background:${c.color};`,
                serviceStyle: `color:${c.color};font-weight:600;`
            }));
        } catch (e) {
            this._showError('Failed to load vendors: ' + this._errMsg(e));
        } finally {
            this.loadingCompanies = false;
        }
    }

    // ── Screen getters ─────────────────────────────────────────────────────
    get isCompanyScreen() { return this.currentScreen === 'companies'; }
    get isBookingScreen() { return this.currentScreen === 'booking';   }
    get isFormScreen()    { return this.currentScreen === 'form';      }
    get isConfirmScreen() { return this.currentScreen === 'confirm';   }

    // ── Company selection ──────────────────────────────────────────────────
    handleSelectCompany(event) {
        const id = event.currentTarget.dataset.id;
        this.selectedCompany  = this.companies.find(c => c.id === id);
        this.slotsByDate      = {};
        this._loadedMonths    = new Set();
        this._loadingMonths   = new Set();
        this.selectedDate     = null;
        this.selectedSlot     = null;
        this.calYear          = new Date().getFullYear();
        this.calMonth         = new Date().getMonth();
        this.currentScreen    = 'booking';
        this._fetchSlotsForMonth(this.calYear, this.calMonth);
    }

    handleBackToCompanies() {
        this.selectedCompany = null;
        this.currentScreen   = 'companies';
    }

    // ── Calendar getters ───────────────────────────────────────────────────
    get calMonthLabel() {
        return MONTH_NAMES[this.calMonth] + ' ' + this.calYear;
    }

    get calendarDays() {
        const today    = new Date(); today.setHours(0, 0, 0, 0);
        const firstDay = new Date(this.calYear, this.calMonth, 1).getDay();
        const lastDay  = new Date(this.calYear, this.calMonth + 1, 0).getDate();
        const days     = [];
        const color    = this.selectedCompany ? this.selectedCompany.color : '#E31837';

        for (let i = 0; i < firstDay; i++) {
            days.push({ key: `b${i}`, label: '', cssClass: 'cal-day blank', style: '' });
        }
        for (let d = 1; d <= lastDay; d++) {
            const date  = new Date(this.calYear, this.calMonth, d);
            const key   = this._dateKey(date);
            const isPast   = date < today;
            const isToday  = date.getTime() === today.getTime();
            const hasSlots = !isPast && (this.slotsByDate[key] || []).length > 0;
            const isSel    = this.selectedDate === key;

            let css = 'cal-day';
            if (isPast)   css += ' cal-past';
            if (isToday)  css += ' cal-today';
            if (hasSlots) css += ' cal-has-slots';
            if (isSel)    css += ' cal-selected';

            const style = hasSlots && !isSel
                ? `color:${color};font-weight:700;cursor:pointer;`
                : isPast ? 'cursor:default;' : '';

            days.push({ key, label: d, cssClass: css, style });
        }
        return days;
    }

    handlePrevMonth() {
        if (this.calMonth === 0) { this.calMonth = 11; this.calYear--; }
        else { this.calMonth--; }
        this._fetchSlotsForMonth(this.calYear, this.calMonth);
    }

    handleNextMonth() {
        if (this.calMonth === 11) { this.calMonth = 0; this.calYear++; }
        else { this.calMonth++; }
        this._fetchSlotsForMonth(this.calYear, this.calMonth);
    }

    handleSelectDate(event) {
        const key = event.currentTarget.dataset.key;
        if (!key || key.startsWith('b')) return;
        if (!(this.slotsByDate[key] || []).length) return;
        this.selectedDate = key;
        this.selectedSlot = null;
    }

    get selectedDateLabel() {
        if (!this.selectedDate) return '';
        const [y, m, d] = this.selectedDate.split('-').map(Number);
        return new Date(y, m - 1, d).toLocaleDateString('en-US', {
            weekday: 'long', month: 'long', day: 'numeric', year: 'numeric'
        });
    }

    get selectedDateSlots() {
        if (!this.selectedDate) return [];
        const color = this.selectedCompany ? this.selectedCompany.color : '#E31837';
        return (this.slotsByDate[this.selectedDate] || []).map((s, i) => {
            const isSel = this.selectedSlot && this.selectedSlot.startTime === s.startTime;
            return {
                key:       `sl-${i}`,
                index:     i,
                label:     this._formatTime(s.startTime),
                startTime: s.startTime,
                endTime:   s.endTime,
                cssClass:  'slot-btn' + (isSel ? ' slot-selected' : ''),
                style:     isSel
                    ? `background:${color};border-color:${color};color:#fff;`
                    : `border-color:#ddd;color:#333;`
            };
        });
    }

    get hasSelectedDateSlots() {
        return this.selectedDateSlots.length > 0;
    }

    handleSelectSlot(event) {
        const idx   = parseInt(event.currentTarget.dataset.index, 10);
        const slots = this.slotsByDate[this.selectedDate] || [];
        this.selectedSlot = slots[idx];
        // Advance to form after brief highlight
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        setTimeout(() => { this.currentScreen = 'form'; }, 300);
    }

    // ── Form screen ────────────────────────────────────────────────────────
    get selectedSlotLabel() {
        if (!this.selectedSlot) return '';
        return this.selectedDateLabel + ' · ' + this._formatTime(this.selectedSlot.startTime) + ' ET';
    }

    get submitBtnLabel() {
        return this.bookingInProgress ? 'Confirming…' : 'Confirm Appointment';
    }

    get submitBtnClass() {
        return this.bookingInProgress ? 'submit-btn submit-btn-disabled' : 'submit-btn';
    }

    get customerDisplay() {
        return (this.firstName + ' ' + this.lastName).trim() + ' · ' + this.email;
    }

    handleBackToBooking() {
        this.currentScreen = 'booking';
    }

    handleFieldChange(event) {
        const field = event.currentTarget.dataset.field;
        this[field] = event.target.value;
    }

    async handleSubmit() {
        if (!this.firstName.trim() || !this.lastName.trim() || !this.email.trim()) {
            this._showError('Please fill in all required fields (first name, last name, email).');
            return;
        }
        if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(this.email)) {
            this._showError('Please enter a valid email address.');
            return;
        }

        this.bookingInProgress = true;
        try {
            const ids  = COMPANY_IDS[this.selectedCompany.id] || {};
            const raw  = await createBookingApex({
                workTypeGroupId: ids.workTypeGroupId,
                workTypeId:      ids.workTypeId,
                schedStartTime:  this.selectedSlot.startTime,
                schedEndTime:    this.selectedSlot.endTime,
                firstName:       this.firstName,
                lastName:        this.lastName,
                email:           this.email,
                phone:           this.phone || '',
                notes:           this.notes || '',
                companyName:     this.selectedCompany.name,
                serviceName:     this.selectedCompany.service
            });
            const result = JSON.parse(raw);
            this.confirmApptId = result.serviceAppointmentId
                ? 'Appointment ID: ' + result.serviceAppointmentId
                : '';
            this.currentScreen = 'confirm';
        } catch (e) {
            this._showError('Booking failed: ' + this._errMsg(e));
        } finally {
            this.bookingInProgress = false;
        }
    }

    handleNewBooking() {
        this.currentScreen   = 'companies';
        this.selectedCompany = null;
        this.selectedDate    = null;
        this.selectedSlot    = null;
        this.firstName = this.lastName = this.email = this.phone = this.notes = '';
        this.confirmApptId   = '';
        this.slotsByDate     = {};
        this._loadedMonths   = new Set();
        this._loadingMonths  = new Set();
    }

    // ── Slot fetching ──────────────────────────────────────────────────────
    async _fetchSlotsForMonth(year, month) {
        const key = `${year}-${String(month).padStart(2, '0')}`;
        if (this._loadedMonths.has(key) || this._loadingMonths.has(key)) return;

        this._loadingMonths.add(key);
        this.loadingSlots = true;

        try {
            const ids   = COMPANY_IDS[this.selectedCompany.id] || {};
            const start = new Date(year, month, 1);
            const end   = new Date(year, month + 1, 1);

            const raw    = await getAvailableSlotsApex({
                workTypeGroupId: ids.workTypeGroupId,
                startDate:       start.toISOString(),
                endDate:         end.toISOString()
            });
            const parsed   = JSON.parse(raw);
            const incoming = parsed.timeSlots || [];

            const updated = { ...this.slotsByDate };
            incoming.forEach(slot => {
                const dateKey = this._utcToLocalDateKey(slot.startTime);
                if (!updated[dateKey]) updated[dateKey] = [];
                updated[dateKey].push(slot);
            });
            this.slotsByDate = updated;
            this._loadedMonths.add(key);
        } catch (e) {
            const msg = this._errMsg(e);
            console.error('[costcoScheduler] slot fetch error:', msg);
            this._showError('Slot load error: ' + msg);
        } finally {
            this._loadingMonths.delete(key);
            this.loadingSlots = this._loadingMonths.size > 0;
        }
    }

    // ── Utilities ──────────────────────────────────────────────────────────
    _dateKey(date) {
        return date.getFullYear() + '-' +
               String(date.getMonth() + 1).padStart(2, '0') + '-' +
               String(date.getDate()).padStart(2, '0');
    }

    _utcToLocalDateKey(iso) {
        const d = new Date(iso);
        return d.getFullYear() + '-' +
               String(d.getMonth() + 1).padStart(2, '0') + '-' +
               String(d.getDate()).padStart(2, '0');
    }

    _formatTime(iso) {
        return new Date(iso).toLocaleTimeString('en-US', {
            hour: 'numeric', minute: '2-digit', hour12: true,
            timeZone: 'America/New_York'
        });
    }

    _errMsg(e) {
        if (e && e.body && e.body.message) return e.body.message;
        return e && e.message ? e.message : String(e);
    }

    _showError(msg) {
        this.toastMsg  = msg;
        this.showToast = true;
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        setTimeout(() => { this.showToast = false; }, 6000);
    }
}
