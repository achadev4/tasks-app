import { app } from "@azure/functions";
import { tasksHandler } from "../handlers/tasksHttp.js";

app.http("tasks", {
  methods: ["GET", "POST", "PATCH", "DELETE", "OPTIONS"],
  route: "tasks/{id?}",
  authLevel: "anonymous",
  handler: tasksHandler,
});
