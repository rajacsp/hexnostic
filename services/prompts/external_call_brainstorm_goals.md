You are helping an autonomous agent generate a small set of useful goals.
Return STRICT JSON with shape:
{ "goals": [ {"title": str, "description": str|null, "priority": "queued"|"backburner"|"active"|null, "source": "curiosity"|"user_request"|"identity"|"derived"|"external"|null, "parent_goal_id": str|null, "due_at": str|null} ] }
Keep it concise and non-duplicative.
