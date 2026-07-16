// Resource-group-scoped monthly cost budget. RG scope (not subscription) is the only
// option under ADR-0004 — IS grants Contributor on the pre-created RG only — and is
// also the right boundary for interim, where the budget must fence off cc-otel's slice
// of the shared VS-benefits credit rather than the whole subscription.

@description('Budget name.')
param name string

@description('Monthly cost cap in the billing currency (USD).')
param amount int

@description('Email addresses that receive the threshold notifications.')
param contactEmails array

@description('Budget anchor — must be the first of a month. Fixed (not utcNow) so redeploys never shift it, which Azure rejects on an existing budget.')
param startDate string

// Actual thresholds fire on spend already incurred; the Forecasted 100% fires when
// Azure projects the month will blow the cap — the early-warning that catches a burn
// rate heading past 150 USD well before the money is gone.
var thresholds = [
  { type: 'Actual', pct: 50 }
  { type: 'Actual', pct: 75 }
  { type: 'Actual', pct: 90 }
  { type: 'Actual', pct: 100 }
  { type: 'Forecasted', pct: 100 }
]

resource budget 'Microsoft.Consumption/budgets@2024-08-01' = {
  name: name
  properties: {
    category: 'Cost'
    amount: amount
    timeGrain: 'Monthly'
    timePeriod: {
      startDate: startDate
    }
    notifications: toObject(
      thresholds,
      t => '${toLower(t.type)}_${t.pct}',
      t => {
        enabled: true
        operator: 'GreaterThanOrEqualTo'
        threshold: t.pct
        thresholdType: t.type
        contactEmails: contactEmails
      }
    )
  }
}
