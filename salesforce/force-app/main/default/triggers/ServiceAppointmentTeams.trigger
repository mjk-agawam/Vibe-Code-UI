/**
 * After a ServiceAppointment is inserted, asynchronously creates a Teams
 * online meeting via the Microsoft Graph API and writes the join URL back
 * to TeamsJoinUrl__c.
 *
 * Uses @future so the callout never blocks the booking transaction.
 */
trigger ServiceAppointmentTeams on ServiceAppointment (after insert) {
    for (ServiceAppointment sa : Trigger.new) {
        // Only create a meeting if no join URL already exists
        if (String.isBlank(sa.TeamsJoinUrl__c)) {
            TeamsMeetingService.createMeetingForAppointment(sa.Id);
        }
    }
}
