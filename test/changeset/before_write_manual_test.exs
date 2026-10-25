# SPDX-FileCopyrightText: 2019 ash contributors <https://github.com/ash-project/ash/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule Ash.Test.Changeset.BeforeWriteManualTest do
  @moduledoc false
  use ExUnit.Case, async: true

  defmodule SeenTitle do
    @moduledoc false
    use Ash.Resource.Change

    @impl true
    def change(changeset, _opts, _context), do: changeset

    @impl true
    def before_write(changeset, _opts, _context),
      do: {:ok, %{seen_title: Ash.Changeset.get_attribute(changeset, :title)}}
  end

  defmodule ManualSeen do
    @moduledoc false
    use Ash.Resource.ManualUpdate

    @impl true
    def update(changeset, _opts, _context) do
      send(self(), {:manual_update_saw, Ash.Changeset.get_attribute(changeset, :seen_title)})
      Ash.Changeset.apply_attributes(changeset)
    end

    @impl true
    def bulk_update(changesets, _opts, _context) do
      Enum.map(changesets, fn changeset ->
        send(
          self(),
          {:manual_bulk_update_saw, Ash.Changeset.get_attribute(changeset, :seen_title)}
        )

        {:ok, record} = Ash.Changeset.apply_attributes(changeset)

        record =
          record
          |> Ash.Resource.put_metadata(:bulk_update_index, changeset.context.bulk_update.index)
          |> Ash.Resource.put_metadata(:bulk_action_ref, changeset.context.bulk_update.ref)

        {:ok, record}
      end)
    end
  end

  defmodule Post do
    @moduledoc false
    use Ash.Resource,
      domain: Ash.Test.Domain,
      data_layer: Ash.DataLayer.Ets

    ets do
      private? true
    end

    attributes do
      uuid_primary_key :id
      attribute :title, :string, public?: true
      attribute :seen_title, :string, public?: true
    end

    actions do
      defaults [:read, create: [:title]]

      update :manual_seen do
        require_atomic? false
        accept [:title]
        manual ManualSeen
        change SeenTitle
      end
    end
  end

  test "a manual update is given the callback's values" do
    post = Ash.create!(Post, %{title: "A"})

    assert %{seen_title: "B"} = Ash.update!(post, %{title: "B"}, action: :manual_seen)
    assert_received {:manual_update_saw, "B"}
  end

  test "a manual bulk update is given the callback's values" do
    post = Ash.create!(Post, %{title: "A"})

    assert %Ash.BulkResult{status: :success, records: [record]} =
             Ash.bulk_update([post], :manual_seen, %{title: "B"},
               strategy: :stream,
               return_records?: true,
               return_errors?: true
             )

    assert record.seen_title == "B"
    assert_received {:manual_bulk_update_saw, "B"}
  end
end
