# GPTel Auto-Compact Context Implementation Plan

## Overview

This document outlines the proposed implementation for auto-compact context functionality in gptel, which will automatically manage conversation history to prevent token limit issues while maintaining conversation coherence.

## Current Architecture Analysis

### Existing Components
- **Manual Context Limiting**: `gptel--num-messages-to-send` already provides manual conversation truncation
- **Context Management**: `gptel-context.el` handles additional context sources (files, buffers, regions)
- **Token Awareness**: `gptel-max-tokens` controls response length limits
- **Request Parsing**: `gptel--parse-buffer` processes conversation history
- **UI Integration**: Transient interface for configuration

### Key Files
- `gptel.el` - Main interface and buffer management
- `gptel-request.el` - Core request handling and conversation parsing
- `gptel-context.el` - Context aggregation and management
- `gptel-transient.el` - Configuration UI
- `gptel-openai.el` - Backend-specific parsing implementations

## Proposed Implementation

### Phase 1: Configuration and Basic Infrastructure

#### User Configuration Variables
```elisp
(defcustom gptel-auto-compact-context nil
  "Automatically compact conversation context when it becomes too large.
  
Values:
- nil: Never auto-compact (current behavior)  
- 'truncate: Remove oldest messages
- 'summarize: Summarize older conversation turns
- 'intelligent: Use LLM to create concise summary"
  :type '(choice (const nil) (const truncate) (const summarize) (const intelligent)))

(defcustom gptel-auto-compact-threshold 0.75
  "Threshold for auto-compacting as ratio of model's max tokens."
  :type 'float)

(defcustom gptel-auto-compact-target 0.5  
  "Target token ratio after auto-compaction."
  :type 'float)
```

#### Token Estimation Functions
```elisp
(defun gptel--estimate-tokens (text)
  "Rough estimation of token count for TEXT (~4 chars per token).")

(defun gptel--get-model-max-tokens ()
  "Get maximum context length for current model.")

(defun gptel--estimate-conversation-tokens ()
  "Estimate token count of current conversation.")
```

### Phase 2: Core Compaction Logic

#### Main Auto-Compaction Function
```elisp
(defun gptel--auto-compact-context ()
  "Auto-compact conversation context if it exceeds threshold.
  
Process:
1. Estimate current conversation token count
2. Compare against model's max tokens * threshold
3. If exceeded, apply selected compaction strategy
4. Target reduction to max tokens * target ratio"
```

#### Compaction Strategies

**Truncation (Phase 1 - Immediate Implementation)**
- Simple removal of oldest messages
- Fast and reliable
- Uses existing `gptel--num-messages-to-send` mechanism

**Summarization (Phase 2)**  
- Create summaries of older conversation portions
- Preserves more context than truncation
- Uses LLM itself for summarization

**Intelligent (Phase 3)**
- Advanced context preservation
- Identifies important conversation elements
- Maintains conversation coherence

### Phase 3: Integration Points

#### Request Pipeline Integration
Modify `gptel--create-prompt-buffer` to check and apply auto-compaction before processing requests.

#### UI Integration
Add transient interface options:
```elisp
(transient-define-infix gptel--infix-auto-compact ()
  "Auto-compact conversation context configuration"
  :key "-A"
  :choices '(nil truncate summarize intelligent))
```

## Implementation Benefits

### Automatic Management
- No user intervention required once configured
- Prevents failed requests due to context limits
- Maintains conversation flow

### Flexible Strategies
- Multiple approaches for different use cases
- User-configurable thresholds and targets
- Backward compatible with existing functionality

### Efficient Resource Usage
- Prevents expensive oversized requests
- Optimizes token usage
- Reduces API costs

## Implementation Phases

### Phase 1: Basic Truncation (Immediate)
- [ ] Add configuration variables
- [ ] Implement token estimation
- [ ] Create truncation-based auto-compaction
- [ ] Integrate with request pipeline
- [ ] Add basic UI controls

### Phase 2: Enhanced Features (Short-term)
- [ ] Improve token estimation accuracy
- [ ] Add model-specific context limits
- [ ] Implement summarization strategy
- [ ] Enhanced configuration options

### Phase 3: Advanced Intelligence (Long-term)
- [ ] Intelligent context preservation
- [ ] Conversation importance analysis
- [ ] Advanced summarization techniques
- [ ] Performance optimizations

## Technical Considerations

### Token Estimation Challenges
- Different models have different tokenization
- Need model-specific token counting
- Balance accuracy vs. performance

### Context Preservation
- Maintain conversation coherence
- Preserve important context elements
- Handle multi-turn conversations appropriately

### Performance Impact
- Minimize overhead for auto-compaction checks
- Async processing for summarization
- Caching for repeated operations

## Next Steps

1. **Start with Phase 1**: Implement basic truncation auto-compaction
2. **Test with various conversation lengths** and model limits
3. **Gather user feedback** on threshold defaults and behavior
4. **Iterate on token estimation accuracy**
5. **Expand to summarization strategies**

## Code Locations for Implementation

- **Configuration**: Add to `gptel-request.el` user options section
- **Core Logic**: Implement in `gptel-request.el` near existing parsing functions  
- **Integration**: Modify `gptel--create-prompt-buffer` in `gptel-request.el`
- **UI**: Extend transient interface in `gptel-transient.el`
- **Backend Support**: Add model context limits to backend files

This implementation will provide gptel users with automatic context management while maintaining the flexibility and power of the existing system.