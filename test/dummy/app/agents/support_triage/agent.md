---
name: Support triage
description: Reads a support ticket and sets its priority.
model: claude-opus-5-5
tools:
  - type: agent_toolset_20260401
    default_config:
      enabled: false
  - type: custom
    name: set_priority
    description: Set the priority of the ticket being triaged.
    input_schema:
      type: object
      properties:
        priority:
          type: string
          enum: [low, normal, high]
        reason:
          type: string
      required: [priority]
---

You triage support tickets for <%= Rails.application.class.module_parent_name %>.
Read the ticket, decide how urgent it is, and call set_priority once.
