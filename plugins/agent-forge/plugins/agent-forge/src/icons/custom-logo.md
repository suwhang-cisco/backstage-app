## Adding a Custom Logo

To use your own logo:

1. Add your image file (PNG or SVG recommended) to this directory
2. Then update the import statement in ChatAssistantApp.tsx to point to your new image

For example, if you add a file named "my-logo.png", update the import to:
```typescript
import WebexLogo from '../icons/my-logo.png';
```

### Best practices for chat logo images:
- Ideal size: 60px × 60px
- Format: PNG or SVG with transparency
- Style: Simple, high contrast design that works on both light and dark backgrounds
