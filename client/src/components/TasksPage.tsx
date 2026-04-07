import { useMsal } from "@azure/msal-react";
import {
  ActionIcon,
  Badge,
  Button,
  ColorInput,
  FileButton,
  Group,
  Paper,
  Stack,
  Switch,
  Text,
  TextInput,
  Title,
} from "@mantine/core";
import { DatePickerInput } from "@mantine/dates";
import { useForm } from "@mantine/form";
import type { Task } from "@tasks-app/shared";
import { useCallback, useEffect, useState } from "react";
import * as api from "../api/client";

const PRESET_COLORS = [
  "#228be6",
  "#40c057",
  "#fab005",
  "#fd7e14",
  "#fa5252",
  "#7950f2",
  "#868e96",
];

export function TasksPage() {
  const { instance, accounts } = useMsal();
  const account = accounts[0] ?? null;
  const [tasks, setTasks] = useState<Task[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const load = useCallback(async () => {
    setError(null);
    setLoading(true);
    try {
      const data = await api.fetchTasks(instance, account);
      setTasks(data);
    } catch (e) {
      setError(e instanceof Error ? e.message : "Failed to load tasks");
    } finally {
      setLoading(false);
    }
  }, [instance, account]);

  useEffect(() => {
    void load();
  }, [load]);

  const form = useForm({
    initialValues: {
      title: "",
      dueDate: null as Date | null,
      category: "",
      color: PRESET_COLORS[0]!,
    },
    validate: {
      title: (v) => (v.trim().length ? null : "Title is required"),
    },
  });

  const handleCreate = form.onSubmit(async (values) => {
    setError(null);
    try {
      await api.createTaskApi(instance, account, {
        title: values.title.trim(),
        dueDate: values.dueDate ? values.dueDate.toISOString().slice(0, 10) : null,
        category: values.category.trim() || null,
        color: values.color || null,
      });
      form.reset();
      await load();
    } catch (e) {
      setError(e instanceof Error ? e.message : "Could not create task");
    }
  });

  const toggleDone = async (task: Task) => {
    setError(null);
    try {
      await api.patchTaskApi(instance, account, task.id, { completed: !task.completed });
      await load();
    } catch (e) {
      setError(e instanceof Error ? e.message : "Update failed");
    }
  };

  const remove = async (id: string) => {
    setError(null);
    try {
      await api.deleteTaskApi(instance, account, id);
      await load();
    } catch (e) {
      setError(e instanceof Error ? e.message : "Delete failed");
    }
  };

  const uploadFile = async (taskId: string, file: File | null) => {
    if (!file) return;
    setError(null);
    try {
      await api.uploadAttachmentApi(instance, account, taskId, file);
      await load();
    } catch (e) {
      setError(e instanceof Error ? e.message : "Upload failed");
    }
  };

  return (
    <Stack gap="lg" maw={720} mx="auto">
      <Title order={3}>Your tasks</Title>
      {error && (
        <Paper p="sm" withBorder bg="red.0">
          <Text size="sm" c="red.9">
            {error}
          </Text>
        </Paper>
      )}

      <Paper withBorder p="md" radius="md">
        <form onSubmit={handleCreate}>
          <Stack gap="sm">
            <TextInput label="Title" required {...form.getInputProps("title")} />
            <DatePickerInput label="Due date" clearable {...form.getInputProps("dueDate")} />
            <TextInput label="Category" placeholder="Work, Personal, …" {...form.getInputProps("category")} />
            <ColorInput label="Color" format="hex" swatches={PRESET_COLORS} {...form.getInputProps("color")} />
            <Button type="submit">Add task</Button>
          </Stack>
        </form>
      </Paper>

      {loading ? (
        <Text size="sm" c="dimmed">
          Loading…
        </Text>
      ) : (
        <Stack gap="sm">
          {tasks.length === 0 ? (
            <Text c="dimmed" size="sm">
              No tasks yet.
            </Text>
          ) : (
            tasks.map((task) => (
              <Paper
                key={task.id}
                withBorder
                p="md"
                radius="md"
                style={{ borderLeftWidth: 4, borderLeftColor: task.color ?? "#228be6" }}
              >
                <Group justify="space-between" align="flex-start" wrap="nowrap">
                  <Stack gap={4} style={{ flex: 1 }}>
                    <Group gap="xs">
                      <Switch checked={task.completed} onChange={() => void toggleDone(task)} />
                      <Text td={task.completed ? "line-through" : undefined} fw={500}>
                        {task.title}
                      </Text>
                    </Group>
                    <Group gap="xs">
                      {task.category && (
                        <Badge variant="light" color="gray">
                          {task.category}
                        </Badge>
                      )}
                      {task.dueDate && (
                        <Text size="xs" c="dimmed">
                          Due {task.dueDate}
                        </Text>
                      )}
                    </Group>
                    <FileButton onChange={(f) => void uploadFile(task.id, f)} accept="*">
                      {(props) => (
                        <Button {...props} variant="light" size="xs">
                          Attach file
                        </Button>
                      )}
                    </FileButton>
                  </Stack>
                  <ActionIcon
                    variant="subtle"
                    color="red"
                    aria-label="Delete task"
                    onClick={() => void remove(task.id)}
                  >
                    ×
                  </ActionIcon>
                </Group>
              </Paper>
            ))
          )}
        </Stack>
      )}
    </Stack>
  );
}
