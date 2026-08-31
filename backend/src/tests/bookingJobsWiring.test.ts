const schedule = jest.fn();
const runOnce = jest.fn();

jest.mock('node-cron', () => ({
  __esModule: true,
  default: { schedule },
}));

jest.mock('../services/bookingNotificationOutboxService.js', () => ({
  bookingNotificationOutboxWorker: { runOnce },
}));

describe('booking job wiring', () => {
  beforeEach(() => {
    jest.clearAllMocks();
    runOnce.mockResolvedValue({ claimed: 0, delivered: 0, failed: 0 });
  });

  it('schedules only the leased notification outbox worker', async () => {
    const { startBookingJobs } = await import('../jobs/bookingJobs.js');

    startBookingJobs();

    expect(schedule).toHaveBeenCalledTimes(1);
    expect(schedule).toHaveBeenCalledWith('* * * * *', expect.any(Function));

    const scheduledWorker = schedule.mock.calls[0][1] as () => Promise<void>;
    await scheduledWorker();
    expect(runOnce).toHaveBeenCalledTimes(1);
  });
});
