---
name: Feature request
about: Propose a new feature or enhancement
title: "[FEATURE] "
labels: enhancement
assignees: ''
---

## Motivation

Why is this feature useful? What problem does it solve?

## Proposed Implementation

What should the feature do? How should the user experience it?

## Files to Touch

Based on the architecture in `docs/DEVELOPER_GUIDE.md`, which files are likely affected?

- [ ] `lib/models/message.dart` — new MessageType or field
- [ ] `lib/services/chat_service.dart` — new Firestore method
- [ ] `lib/controllers/chat_controller.dart` — new business logic
- [ ] `lib/repositories/i_chat_repository.dart` — new interface method
- [ ] `lib/repositories/firebase_chat_repository.dart` — new adapter method
- [ ] `lib/screens/chat_screen.dart` — UI change
- [ ] `lib/widgets/message_bubble.dart` — new bubble content
- [ ] `lib/features/call/` — call-related change
- [ ] `lib/constants.dart` + Remote Config — new runtime config key
- [ ] Other: ___

## Alternatives Considered

Any alternative approaches you considered and why you chose this one.

## Additional Context

Mockups, links to similar features in other apps, or any other relevant context.
