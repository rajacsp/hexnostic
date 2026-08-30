#!/usr/bin/env python3
"""
Hexis Memory MCP Tools (Legacy Sync Adapter)

This module retains only the ApiMemoryToolHandler and get_tool_definitions()
for use by core/tools/sync_adapter.py. The canonical async tool handlers
live in core/tools/memory.py.
"""

from typing import Any

from core.cognitive_memory_api import (
    CognitiveMemorySync,
    GoalPriority as ApiGoalPriority,
    GoalSource as ApiGoalSource,
    MemoryType as ApiMemoryType,
)


# Minimal tool definitions for the sync adapter (OpenAI function-calling format).
# The canonical definitions are in core/tools/memory.py; these exist only so
# CombinedToolHandler.get_tool_definitions() can expose legacy memory tools.
_API_TOOL_NAMES = {
    "recall",
    "sense_memory_availability",
    "request_background_search",
    "recall_recent",
    "explore_concept",
    "get_procedures",
    "get_strategies",
    "create_goal",
    "queue_user_message",
}

MEMORY_TOOLS: list[dict[str, Any]] = [
    {
        "type": "function",
        "function": {
            "name": name,
            "description": f"Legacy memory tool: {name}",
            "parameters": {"type": "object", "properties": {}},
        },
    }
    for name in sorted(_API_TOOL_NAMES)
]


class ApiMemoryToolHandler:
    """Tool handler backed by CognitiveMemorySync (asyncpg).

    Used only by core/tools/sync_adapter.py for the legacy conversation loop.
    """

    def __init__(self, db_config: dict):
        self.db_config = db_config
        self.client: CognitiveMemorySync | None = None

    def connect(self) -> None:
        if self.client is not None:
            return
        dsn = (
            f"postgresql://{self.db_config.get('user', 'postgres')}:{self.db_config.get('password', 'password')}"
            f"@{self.db_config.get('host', 'localhost')}:{int(self.db_config.get('port', 43815))}"
            f"/{self.db_config.get('dbname', 'hexis_memory')}"
        )
        from core.agent_api import pool_sizes_from_env
        _min, _max = pool_sizes_from_env(1, 5)
        self.client = CognitiveMemorySync.connect(dsn, min_size=_min, max_size=_max)

    def close(self) -> None:
        if self.client is not None:
            self.client.close()
            self.client = None

    def execute_tool(self, tool_name: str, arguments: dict) -> dict:
        self.connect()
        assert self.client is not None

        handlers = {
            "recall": self._handle_recall,
            "sense_memory_availability": self._handle_sense_memory_availability,
            "request_background_search": self._handle_request_background_search,
            "recall_recent": self._handle_recall_recent,
            "explore_concept": self._handle_explore_concept,
            "get_procedures": self._handle_get_procedures,
            "get_strategies": self._handle_get_strategies,
            "create_goal": self._handle_create_goal,
            "queue_user_message": self._handle_queue_user_message,
        }
        handler = handlers.get(tool_name)
        if not handler:
            return {"error": f"Unknown tool: {tool_name}"}
        try:
            return handler(arguments or {})
        except Exception as e:
            return {"error": str(e)}

    def _handle_recall(self, args: dict) -> dict:
        query = args.get("query", "")
        limit = min(int(args.get("limit", 5)), 20)
        memory_types = args.get("memory_types")
        min_importance = float(args.get("min_importance", 0.0) or 0.0)

        parsed_types = None
        if isinstance(memory_types, list) and memory_types:
            parsed_types = [ApiMemoryType(str(t)) for t in memory_types]

        result = self.client.recall(query, limit=limit, memory_types=parsed_types, min_importance=min_importance, include_partial=False)
        self.client.touch_memories([m.id for m in result.memories])
        memories = [
            {
                "memory_id": str(m.id),
                "content": m.content,
                "memory_type": m.type.value,
                "score": m.similarity,
                "source": m.source,
                "importance": m.importance,
                "trust_level": m.trust_level,
                "source_attribution": m.source_attribution,
            }
            for m in result.memories
        ]
        return {"memories": memories, "count": len(memories), "query": query}

    def _handle_sense_memory_availability(self, args: dict) -> dict:
        query = str(args.get("query", "")).strip()
        if not query:
            return {"error": "Missing query"}
        payload = self.client.sense_memory_availability(query)
        return payload if isinstance(payload, dict) else {"result": payload}

    def _handle_request_background_search(self, args: dict) -> dict:
        query = str(args.get("query", "")).strip()
        if not query:
            return {"error": "Missing query"}
        activation_id = self.client.request_background_search(query)
        return {"activation_id": str(activation_id) if activation_id else None}

    def _handle_recall_recent(self, args: dict) -> dict:
        limit = min(int(args.get("limit", 5)), 20)
        memory_types = args.get("memory_types")

        mt = None
        if isinstance(memory_types, list) and memory_types:
            mt = ApiMemoryType(str(memory_types[0]))

        memories = self.client.recent(limit=limit, memory_type=mt)
        return {
            "memories": [
                {
                    "memory_id": str(m.id),
                    "content": m.content,
                    "memory_type": m.type.value,
                    "importance": m.importance,
                }
                for m in memories
            ],
            "count": len(memories),
        }

    def _handle_explore_concept(self, args: dict) -> dict:
        concept = str(args.get("concept", "")).strip()
        if not concept:
            return {"error": "Missing concept"}
        limit = min(int(args.get("limit", 3)), 10)
        result = self.client.explore_clusters(concept, limit=limit)
        return {"clusters": result, "count": len(result)}

    def _handle_get_procedures(self, args: dict) -> dict:
        query = str(args.get("query", "")).strip()
        if not query:
            return {"error": "Missing query"}
        limit = min(int(args.get("limit", 3)), 10)
        result = self.client.recall(query, limit=limit, memory_types=[ApiMemoryType.PROCEDURAL], include_partial=False)
        return {
            "procedures": [
                {"memory_id": str(m.id), "content": m.content, "importance": m.importance}
                for m in result.memories
            ],
            "count": len(result.memories),
        }

    def _handle_get_strategies(self, args: dict) -> dict:
        query = str(args.get("query", "")).strip()
        if not query:
            return {"error": "Missing query"}
        limit = min(int(args.get("limit", 3)), 10)
        result = self.client.recall(query, limit=limit, memory_types=[ApiMemoryType.STRATEGIC], include_partial=False)
        return {
            "strategies": [
                {"memory_id": str(m.id), "content": m.content, "importance": m.importance}
                for m in result.memories
            ],
            "count": len(result.memories),
        }

    def _handle_create_goal(self, args: dict) -> dict:
        title = str(args.get("title", "")).strip()
        if not title:
            return {"error": "Missing title"}
        description = args.get("description")
        priority = args.get("priority", "medium")
        source = args.get("source", "agent")
        due_at_raw = args.get("due_at")
        due_at = str(due_at_raw) if due_at_raw else None

        goal_id = self.client.create_goal(
            title=title,
            description=description,
            source=ApiGoalSource(source) if source else ApiGoalSource.AGENT,
            priority=ApiGoalPriority(priority) if priority else ApiGoalPriority.MEDIUM,
            due_at=due_at,
        )
        return {"goal_id": str(goal_id), "title": title, "priority": priority, "source": source, "due_at": due_at_raw}

    def _handle_queue_user_message(self, args: dict) -> dict:
        message = str(args.get("message", "")).strip()
        if not message:
            return {"error": "Missing message"}

        intent = args.get("intent")
        context = args.get("context")
        outbox_message = self.client.queue_user_message(
            message,
            intent=str(intent) if isinstance(intent, str) else None,
            context=context if isinstance(context, dict) else None,
        )
        return {"outbox_message": outbox_message, "queued": True}


def get_tool_definitions() -> list:
    """Return tool definitions for function calling (sync adapter)."""
    return [t for t in MEMORY_TOOLS if t.get("function", {}).get("name") in _API_TOOL_NAMES]


def create_tool_handler(db_config: dict) -> ApiMemoryToolHandler:
    """Create an API-backed tool handler instance."""
    return ApiMemoryToolHandler(db_config)
